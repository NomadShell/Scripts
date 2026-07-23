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

## Host Helper updates

Host Helper updates are independent of the iPhone App version. Release `0.1.4`
and newer check `dist/latest.json` automatically, verify the release SHA-256,
and roll back if the restarted daemon does not report the expected version.
The manifest keeps bridge protocol v1 available so old and new App builds use
the same mobile API contract.

On hosts where the system npm prefix requires root, quick setup migrates Host
Helper into the user's `~/.local` prefix and records that bin directory in
`~/.profile`. Existing `0.1.3` installations must run quick setup once because
that version predates the updater; later releases update without rerunning the
App setup flow.

## Tests

```bash
bash test/quick-setup.test.sh
shellcheck quick-setup.sh generate-nomad-qr.sh test/quick-setup.test.sh
pwsh -NoProfile -File test/quick-setup.Tests.ps1
```
