#!/usr/bin/env python3
"""Local WSL2 archive installation. Cloud enrollment is a separate operation."""
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


def run(arguments, timeout=120):
    result = subprocess.run(arguments, stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f'{Path(arguments[0]).name} failed ({result.returncode}): '
                           f'{result.stderr[-8192:]}{result.stdout[-8192:]}')
    return result.stdout


def resources(proc_root=Path('/proc'), cgroup_root=Path('/sys/fs/cgroup')):
    memory = {}
    for line in (proc_root / 'meminfo').read_text().splitlines():
        fields = line.split()
        if fields[0] in ('MemTotal:', 'MemAvailable:', 'SwapTotal:'):
            memory[fields[0][:-1]] = int(fields[1]) * 1024
    result = {'logicalCPUs': os.cpu_count(), 'allowedCPUs': len(os.sched_getaffinity(0)),
              'memoryBytes': memory['MemTotal'], 'availableMemoryBytes': memory['MemAvailable'],
              'swapBytes': memory.get('SwapTotal', 0), 'cgroupMemoryLimitBytes': None,
              'cgroupCPUQuota': None}
    # A container may impose tighter limits than the WSL utility VM.
    for line in (proc_root / 'self/cgroup').read_text().splitlines():
        if line.startswith('0::'):
            root = cgroup_root.resolve()
            group = (root / line[3:].lstrip('/')).resolve()
            if not group.is_relative_to(root):
                raise ValueError('Unexpected cgroup path')
            limits = []
            quotas = []
            for directory in [group, *group.parents]:
                if not directory.is_relative_to(root):
                    break
                limit = directory / 'memory.max'
                if limit.exists() and limit.read_text().strip() != 'max':
                    limits.append(int(limit.read_text().strip()))
                quota = directory / 'cpu.max'
                if quota.exists():
                    amount, period = quota.read_text().split()
                    if amount != 'max':
                        quotas.append(int(amount) / int(period))
            result['cgroupMemoryLimitBytes'] = min(limits) if limits else None
            result['cgroupCPUQuota'] = min(quotas) if quotas else None
    return result


def preflight():
    if sys.version_info < (3, 12):
        raise ValueError('Python 3.12 or newer is required; use Ubuntu 24.04')
    if platform.system() != 'Linux' or not all(part in platform.release().lower() for part in ('microsoft', 'wsl2')):
        raise ValueError('Run this installer inside WSL2 on Windows')
    if os.getuid() == 0:
        raise ValueError('Select a WSL distribution with a non-root default development user')
    for tool in ('bash', 'git', 'tar', 'systemctl', 'flock', 'timeout', 'readlink', 'wslpath'):
        if not shutil.which(tool):
            raise ValueError(f'Install the required Linux tool first: {tool}')
    # wsl.exe can start the user without the interactive shell's environment.
    os.environ.setdefault('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
    os.environ.setdefault('DBUS_SESSION_BUS_ADDRESS', f"unix:path={os.environ['XDG_RUNTIME_DIR']}/bus")
    run(['systemctl', '--user', 'show-environment'], timeout=15)
    return resources()


def enable_user_startup():
    import pwd
    user = pwd.getpwuid(os.getuid()).pw_name
    query = ['loginctl', 'show-user', '--property=Linger', '--value', '--', user]
    if run(query, timeout=15).strip() != 'yes':
        run(['loginctl', '--no-ask-password', 'enable-linger', '--', user], timeout=15)
        if run(query, timeout=15).strip() != 'yes':
            raise RuntimeError('The systemd user manager needs lingering enabled before sign-in startup can be configured')


def validate_members(members):
    names = set()
    links = set()
    total = 0
    if len(members) > 100_000:
        raise ValueError('Archive contains too many entries')
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or '\\' in member.name:
            raise ValueError('Archive contains an unsafe path')
        name = str(path)
        if name in names:
            raise ValueError('Archive contains duplicate paths')
        names.add(name)
        if not (member.isfile() or member.isdir() or member.issym()):
            raise ValueError('Archive contains an unsupported entry type')
        if member.issym():
            destination = posixpath.normpath(posixpath.join(str(path.parent), member.linkname))
            if member.linkname.startswith('/') or destination == '..' or destination.startswith('../'):
                raise ValueError('Archive contains an escaping symlink')
            links.add(name)
        total += member.size
    if total > 4 * 1024**3:
        raise ValueError('Expanded archive exceeds 4 GiB')
    for name in names:
        if any(str(parent) in links for parent in PurePosixPath(name).parents):
            raise ValueError('Archive writes through a symlink')


def install_archive(archive, expected_sha256):
    if not re.fullmatch('[0-9a-fA-F]{64}', expected_sha256):
        raise ValueError('Supply a trusted SHA-256 digest for the Linux archive')
    if not hasattr(tarfile, 'data_filter'):
        raise ValueError('Python with safe tar extraction is required; use Ubuntu 24.04')
    with tempfile.TemporaryDirectory(prefix='graftty-wsl-') as scratch:
        root = Path(scratch)
        # Hash and extract the same private copy so a renamed source cannot
        # replace the archive between verification and extraction.
        private_archive = root / 'archive.tar.gz'
        shutil.copyfile(archive, private_archive)
        with private_archive.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        if digest != expected_sha256.lower():
            raise ValueError('Linux archive SHA-256 mismatch; nothing was installed')
        unpacked = root / 'unpacked'
        unpacked.mkdir(mode=0o700)
        with tarfile.open(private_archive, 'r:gz') as bundle:
            members = []
            expanded_bytes = 0
            for member in bundle:
                members.append(member)
                expanded_bytes += member.size
                if len(members) > 100_000 or expanded_bytes > 4 * 1024**3:
                    raise ValueError('Linux archive exceeds the entry or expanded-size limit')
            validate_members(members)
            bundle.extractall(unpacked, members=members, filter='data')
        for name in ('VERSION', 'install.sh', 'bin/graftty-host', 'bin/graftty', 'bin/zmx', 'share/ZMX_UPSTREAM_COMMIT'):
            path = unpacked / name
            if not path.is_file() or path.is_symlink():
                raise ValueError(f'Linux archive is missing a regular file: {name}')
        version = (unpacked / 'VERSION').read_text().strip()
        if not re.fullmatch('[a-zA-Z0-9][a-zA-Z0-9._+-]*', version):
            raise ValueError('Linux archive has an invalid version')
        for binary in ('graftty-host', 'graftty', 'zmx'):
            run([str(unpacked / 'bin' / binary), '--help' if binary != 'zmx' else 'version'], timeout=15)
        # Reuse the transactional Linux installer and its readiness check.
        # Loopback is intentional until endpoint-authenticated outbound access
        # exists. This installer never exposes a public pairing listener.
        run(['/bin/bash', str(unpacked / 'install.sh'), '--bind-address', '127.0.0.1'])
    return {'localReady': True, 'remoteReady': False, 'version': version,
            'connectionStatus': 'Cloud enrollment and the outbound Mac connection are not implemented yet.'}


def main():
    request = json.loads(base64.b64decode(sys.argv[1], validate=True))
    capacity = preflight()
    if request['action'] == 'inspect':
        print(json.dumps({'resources': capacity}))
        return
    if request['action'] != 'install':
        raise ValueError('Unknown WSL setup action')
    archive = Path(run(['wslpath', '-a', '-u', request['archivePath']], timeout=15).strip())
    result = install_archive(archive, request['sha256'])
    if request.get('enableStartup'):
        enable_user_startup()
    result['resources'] = capacity
    result['projectRoot'] = str(Path.home() / 'projects')
    print(json.dumps(result))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
