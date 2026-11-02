# Run Windows installer checks in VirtualBox

Use an installed Windows 11 Vagrant box with WinRM enabled. The harness creates
a dedicated VM with 4 GB RAM, two CPUs, and localhost management ports. It
disables shared folders and copies only the installer and check files.

Box credentials default to the standard Vagrant test account. Set
`GRAFTTY_WINDOWS_USER` and `GRAFTTY_WINDOWS_PASSWORD` in the local environment
first if your box uses another account.

On this macOS host, also set `GRAFTTY_VAGRANT_VERIFIED_PORT_PROBE=1` for the
reproduced Ruby port-probe issue described below. From this directory, select
your local box and start the VM:

```sh
export GRAFTTY_WINDOWS_BOX='your/local-windows11-arm-box'
export GRAFTTY_WINDOWS_ARCH=arm64
export GRAFTTY_VAGRANT_VERIFIED_PORT_PROBE=1
vagrant up --provider virtualbox
```

For an x86 host, select an installed x86 Windows box and use
`GRAFTTY_WINDOWS_ARCH=amd64`.

Provisioning runs the PowerShell configuration and startup-definition checks.
It also registers a temporary task through the production startup helper,
verifies its current-user and limited-permission settings, then removes it.
A temporary registry fixture verifies that the Windows installer rejects
WSL1 before it attempts to launch Linux or install an archive. The fixture
is removed after the check.

Read the results or rerun the checks after editing the scripts:

```sh
vagrant winrm -c 'Get-Content C:\graftty-tests\results.json'
vagrant provision
```

Remove only this harness's VM when finished:

```sh
vagrant destroy -f
```

If Vagrant reports every unused port as occupied on this macOS host, set
`GRAFTTY_VAGRANT_VERIFIED_PORT_PROBE=1` before running it. The optional helper
checks that Ruby's returned socket actually has a connected peer. The local
Vagrant 2.4.9 Ruby runtime returned an unconnected socket with `SO_ERROR=61`
as a successful connection during diagnosis. The helper is scoped to this
harness process and leaves the Vagrant installation unchanged.

## What this proves

These checks exercise Windows PowerShell, Windows file replacement, registry
inspection, and Task Scheduler registration. They use WinRM as test machinery.
The Graftty installation path still requires no SSH access to Windows.

WSL2 needs nested virtualization inside a Windows VM. VirtualBox on the local
M4 Pro reports `Processor supports nested HW virtualization: no`. Oracle also
documents that its nested virtualization setting is unavailable to Arm guests.
See the [VirtualBox 7.2 user guide](https://download.oracle.com/virtualbox/UserManual.pdf),
sections 2.1.2 and 5.13.2.

The harness therefore reports WSL2 runtime as untested. Use native Windows
hardware or a VM host that exposes the necessary virtualization features to
validate WSL2 installation, background lifetime, zmx sessions, and the remote
transport. A passing Windows script check does not establish those behaviors.
