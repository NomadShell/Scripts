# Moshline setup scripts

These scripts prepare a remote machine for pairing with the Moshline iPhone app.
The supported path installs SSH, Mosh, and Moshline Host Helper before it prints a
QR code, so a visible QR code means the required host services passed their
self-checks.

## Platform support

| Remote machine | Setup command | Notes |
| --- | --- | --- |
| macOS | `curl -fsSL https://raw.githubusercontent.com/NomadShell/Scripts/main/quick-setup.sh \| bash` | Remote Login must be allowed; macOS may require Full Disk Access for the terminal that enables it. |
| Linux | `curl -fsSL https://raw.githubusercontent.com/NomadShell/Scripts/main/quick-setup.sh \| bash` | Supports Homebrew, apt, yum, and dnf. Active ufw/firewalld rules are updated; NodeSource 22.x is used when the system Node.js is too old. |
| Windows 11 22H2+ | `irm https://raw.githubusercontent.com/NomadShell/Scripts/main/quick-setup.ps1 \| iex` | Run the first setup from Administrator PowerShell. Uses WSL2, systemd, mirrored networking, and scoped Hyper-V firewall rules. |

Native Windows and Windows Server are not supported hosts. The iPhone app starts
`mosh-server`, while Moshline Host Helper currently installs only as a macOS
LaunchAgent or Linux systemd user service. The Windows script therefore runs the
same Linux setup inside WSL2 and refuses to emit the old native-Windows QR payload.

On Windows, keep the selected WSL distribution running while using Moshline. Use
`-Distro <name>` when more than one distribution is installed. The first setup can
enable mirrored networking or systemd and restart WSL automatically.

## Options

Both quick-setup scripts accept address, SSH user, SSH port, and Host Helper port
overrides. For example:

```bash
bash quick-setup.sh \
  --host server.example.com \
  --user deploy \
  --port 2222 \
  --bridge-port 24000
```

```powershell
.\quick-setup.ps1 `
  -ServerHost server.example.com `
  -User deploy `
  -Port 2222 `
  -BridgePort 24000 `
  -Distro Ubuntu
```

`--skip-system-setup` / `-SkipSystemSetup` is intended for pre-provisioned hosts.
It does not relax readiness checks; required services and network settings must
already exist.

## Tests

```bash
bash test/quick-setup.test.sh
shellcheck quick-setup.sh generate-nomad-qr.sh test/quick-setup.test.sh
pwsh -NoProfile -File test/quick-setup.Tests.ps1
```
