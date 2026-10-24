import Foundation

enum LinuxHostMaintenanceScripts {
    // Bootstrap-compatible inspection: the old host has no read-only identity
    // command. Derive only the public key locally through OpenSSL; neither the
    // private seed nor its JSON record ever leaves the authenticated host.
    private static let identityPython = #"""
    import base64, json, os, pathlib, platform, subprocess, sys
    if platform.system() != 'Linux':
        raise SystemExit('Maintenance requires Linux')
    home = pathlib.Path.home()
    data = pathlib.Path(os.environ.get('XDG_DATA_HOME', str(home / '.local/share')))
    host = home / '.local/bin/graftty-host'
    status = json.loads(subprocess.run([str(host), 'status', '--json'], check=True, capture_output=True, timeout=15).stdout)
    if not status.get('running'):
        raise SystemExit('The existing host must be running for maintenance')
    state = pathlib.Path(status['stateDirectory'])
    identity = json.loads((state / 'Remote/host-identity.json').read_text())
    device = json.loads((state / 'Remote/host-device-id.json').read_text())
    if identity.get('version') != 2 or device.get('version') != 1:
        raise SystemExit('Unsupported identity metadata; no changes made')
    seed = base64.b64decode(identity['privateKeyData'], validate=True)
    if len(seed) != 32:
        raise SystemExit('Invalid identity metadata; no changes made')
    result = subprocess.run(['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
        input=bytes.fromhex('302e020100300506032b657004220420') + seed, capture_output=True, timeout=15)
    if result.returncode or len(result.stdout) != 44 or not result.stdout.startswith(bytes.fromhex('302a300506032b6570032100')):
        raise SystemExit('OpenSSL could not derive the existing public identity')
    public = base64.b64encode(result.stdout[-32:]).decode()
    bundle = host.resolve().parent.parent
    version = (bundle / 'VERSION').read_text().strip()
    value = dict(deviceID=device['deviceID']['value'], publicKey=public, sshPort=status['sshPort'],
        architecture=platform.machine(), version=version, home=str(home), data=str(data))
    """#

    static let probe = """
    set -eu
    # GRAFTTY_MAINTENANCE_PROBE
    python3 - <<'GRAFTTY_READ_IDENTITY_B390'
    \(identityPython)
    print(json.dumps(value))
    GRAFTTY_READ_IDENTITY_B390
    """

    static let serviceOwnershipPython = #"""
    service_pid = int(subprocess.check_output(['systemctl', '--user', 'show', 'graftty-host.service', '--property=MainPID', '--value'], timeout=15).strip())
    lease = (state / 'host.lock').stat()
    owner_matches = False
    for line in pathlib.Path('/proc/locks').read_text().splitlines():
        fields = line.split()
        if len(fields) < 6 or fields[1:4] != ['POSIX', 'ADVISORY', 'WRITE']:
            continue
        major, minor, inode = fields[5].split(':')
        if (int(fields[4]) == service_pid and int(major, 16) == os.major(lease.st_dev)
            and int(minor, 16) == os.minor(lease.st_dev) and int(inode) == lease.st_ino):
            owner_matches = True
    if service_pid <= 0 or not owner_matches:
        raise SystemExit('The installed service does not own this paired host state; no changes made')
    """#

    static func guardIdentity(_ expected: LinuxHostIdentity, version: String? = nil, requireServiceOwner: Bool = false) -> String {
        // JSON encodes these as Python-compatible string literals without
        // exposing private credentials or interpolating executable shell text.
        let payload = try! JSONEncoder().encode(expected).base64EncodedString()
        let versionPayload = version.map { try! JSONEncoder().encode($0).base64EncodedString() }
        return """
        set -eu
        python3 - <<'GRAFTTY_VERIFY_IDENTITY_D782'
        \(identityPython)
        expected = json.loads(base64.b64decode('\(payload)'))
        if value['deviceID'] != expected['deviceID'] or value['publicKey'] != expected['publicKey'] or status['sshPort'] != expected['port']:
            raise SystemExit('Graftty identity or endpoint changed; no changes made')
        \(versionPayload.map { "if value['version'] != json.loads(base64.b64decode('" + $0 + "')):\n    raise SystemExit('Graftty build changed since the host check; check the host again before updating')" } ?? "")
        \(requireServiceOwner ? serviceOwnershipPython : "")
        GRAFTTY_VERIFY_IDENTITY_D782
        """
    }

    static func install(release: LinuxHostRelease, data: String, expected: LinuxHostIdentity, version: String) throws -> String {
        guard let resource = GrafttyKitResourceBundle.bundle.url(forResource: "linux-install", withExtension: "sh") else {
            throw LinuxHostSetupError.invalidPlan("The maintenance installer resource is missing.")
        }
        let installer = try String(contentsOf: resource, encoding: .utf8)
        let staging = data + "/graftty/releases/.maintenance-" + UUID().uuidString
        return """
        set -eu
        umask 077
        mkdir -p -- \(LinuxHostScripts.quote(data + "/graftty/releases"))
        mkdir -- \(LinuxHostScripts.quote(staging))
        maintenance_stage=\(LinuxHostScripts.quote(staging))
        trap 'rm -rf -- "$maintenance_stage"' EXIT
        trap 'exit 130' HUP INT TERM
        \(LinuxHostScripts.install(staging: staging, archiveURL: release.archiveURL, maintenanceInstaller: installer, maintenancePreflight: guardIdentity(expected, version: version, requireServiceOwner: true)))
        """
    }
}
