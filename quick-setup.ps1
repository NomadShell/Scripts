#requires -Version 5.1

param(
  [string]$ServerHost,
  [string]$User,
  [int]$Port = 22,
  [int]$BridgePort = 24000,
  [string]$Distro,
  [switch]$SkipSystemSetup,
  [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WslCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$SetupScriptUrl = if ([string]::IsNullOrWhiteSpace($env:MOSHLINE_SETUP_URL)) {
  'https://raw.githubusercontent.com/NomadShell/Scripts/main/quick-setup.sh'
} else {
  $env:MOSHLINE_SETUP_URL.Trim()
}

function Write-Info {
  param([string]$Message)
  Write-Host "[Moshline] $Message"
}

function Stop-Setup {
  param([string]$Message)
  [Console]::Error.WriteLine("[Moshline] $Message")
  exit 1
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Port {
  param(
    [string]$Label,
    [int]$Value
  )
  if ($Value -lt 1 -or $Value -gt 65535) {
    Stop-Setup "$Label must be between 1 and 65535."
  }
}

function Get-WindowsBuildNumber {
  try {
    return [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
  } catch {
    return [Environment]::OSVersion.Version.Build
  }
}

function Test-IsWindowsWorkstation {
  try {
    return [int](Get-CimInstance Win32_OperatingSystem).ProductType -eq 1
  } catch {
    return $true
  }
}

function Get-InstalledDistros {
  $output = @(& wsl.exe --list --quiet 2>$null)
  if ($LASTEXITCODE -ne 0) {
    return @()
  }
  return @($output |
    ForEach-Object { ($_ -replace "`0", '').Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Ensure-CurrentWSL {
  $versionOutput = @(& wsl.exe --version 2>$null)
  $versionMatch = [regex]::Match(($versionOutput -join "`n"), '(?m)(\d+\.\d+\.\d+(?:\.\d+)?)')
  $currentVersion = if ($LASTEXITCODE -eq 0 -and $versionMatch.Success) {
    [version]$versionMatch.Groups[1].Value
  } else {
    $null
  }
  if ($null -ne $currentVersion -and $currentVersion -ge [version]'2.0.0') {
    return
  }
  if ($SkipSystemSetup) {
    Stop-Setup "WSL 2.0 or newer is required. Run 'wsl --update', then try again."
  }

  Write-Info 'Updating WSL for mirrored networking support...'
  & wsl.exe --update
  if ($LASTEXITCODE -ne 0) {
    Stop-Setup "Unable to update WSL. Run 'wsl --update' from Administrator PowerShell, then try again."
  }
}

function Resolve-Distro {
  param([string[]]$InstalledDistros)

  if (-not [string]::IsNullOrWhiteSpace($Distro)) {
    $match = $InstalledDistros | Where-Object { $_ -eq $Distro } | Select-Object -First 1
    return $match
  }
  return ($InstalledDistros |
    Where-Object { $_ -notmatch '^(docker-desktop(?:-data)?|rancher-desktop|podman-machine-default)$' } |
    Select-Object -First 1)
}

function Invoke-WSLText {
  param(
    [string]$DistroName,
    [string[]]$CommandArguments
  )
  $output = @(& wsl.exe -d $DistroName -- @CommandArguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw ($output -join "`n")
  }
  return ($output -join "`n").Trim()
}

function Ensure-WSL2 {
  param([string]$DistroName)

  $kernel = Invoke-WSLText -DistroName $DistroName -CommandArguments @('uname', '-r')
  if ($kernel -match 'WSL2') {
    return
  }
  if ($SkipSystemSetup) {
    Stop-Setup "'$DistroName' is not running as WSL2. Run 'wsl --set-version $DistroName 2', then try again."
  }
  if (-not (Test-IsAdministrator)) {
    Stop-Setup "Converting '$DistroName' to WSL2 requires an Administrator PowerShell window."
  }
  Write-Info "Converting '$DistroName' to WSL2..."
  & wsl.exe --set-version $DistroName 2
  if ($LASTEXITCODE -ne 0) {
    Stop-Setup "Unable to convert '$DistroName' to WSL2."
  }
}

function Enable-MirroredNetworking {
  param([string]$ConfigPath = (Join-Path $HOME '.wslconfig'))

  $configPath = $ConfigPath
  $content = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath -Raw
  } else {
    ''
  }

  $lineValues = if ([string]::IsNullOrEmpty($content)) {
    @()
  } else {
    @($content -split '\r?\n')
  }
  $lines = New-Object System.Collections.ArrayList
  if ($lineValues.Count -gt 0) {
    [void]$lines.AddRange([string[]]$lineValues)
  }

  $currentSection = ''
  $wsl2Index = -1
  $networkingModeIndex = -1
  for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = [string]$lines[$index]
    if ($line -match '^\s*\[([^]]+)\]\s*$') {
      $currentSection = $Matches[1].Trim().ToLowerInvariant()
      if ($currentSection -eq 'wsl2') {
        $wsl2Index = $index
      }
      continue
    }
    if ($currentSection -eq 'wsl2' -and $line -match '^\s*networkingMode\s*=\s*(.*?)\s*$') {
      $networkingModeIndex = $index
      if ($Matches[1] -eq 'mirrored') {
        return $false
      }
    }
  }

  if ($networkingModeIndex -ge 0) {
    $lines[$networkingModeIndex] = 'networkingMode=mirrored'
  } elseif ($wsl2Index -ge 0) {
    $lines.Insert($wsl2Index + 1, 'networkingMode=mirrored')
  } else {
    if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$lines[$lines.Count - 1])) {
      [void]$lines.Add('')
    }
    [void]$lines.Add('[wsl2]')
    [void]$lines.Add('networkingMode=mirrored')
  }

  if ($SkipSystemSetup) {
    Stop-Setup "WSL mirrored networking is required. Add 'networkingMode=mirrored' under '[wsl2]' in $configPath, run 'wsl --shutdown', then try again."
  }

  $updatedContent = ([string[]]$lines) -join "`r`n"
  Set-Content -LiteralPath $configPath -Value $updatedContent -Encoding UTF8
  Write-Info "Enabled WSL mirrored networking in $configPath."
  return $true
}

function Ensure-Systemd {
  param([string]$DistroName)

  $initName = Invoke-WSLText -DistroName $DistroName -CommandArguments @(
    'sh', '-lc', 'ps -p 1 -o comm= | tr -d "[:space:]"'
  )
  if ($initName -eq 'systemd') {
    return $false
  }
  if ($SkipSystemSetup) {
    Stop-Setup "systemd is required in '$DistroName'. Enable it in /etc/wsl.conf, run 'wsl --shutdown', then try again."
  }

  Write-Info "Enabling systemd in '$DistroName' (sudo may ask for the Linux password)..."
  $command = @'
set -e
if sudo grep -Eq '^[[:space:]]*systemd[[:space:]]*=' /etc/wsl.conf 2>/dev/null; then
  sudo sed -i -E 's/^[[:space:]]*systemd[[:space:]]*=.*/systemd=true/' /etc/wsl.conf
elif sudo grep -Eq '^[[:space:]]*\[boot\][[:space:]]*$' /etc/wsl.conf 2>/dev/null; then
  sudo sed -i -E '/^[[:space:]]*\[boot\][[:space:]]*$/a systemd=true' /etc/wsl.conf
else
  printf '\n[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
fi
'@
  try {
    [void](Invoke-WSLText -DistroName $DistroName -CommandArguments @('sh', '-lc', $command))
  } catch {
    Stop-Setup "Unable to enable systemd in '$DistroName': $($_.Exception.Message)"
  }
  return $true
}

function Ensure-HyperVFirewallRule {
  param(
    [string]$Name,
    [string]$DisplayName,
    [string]$Protocol,
    [string[]]$LocalPorts
  )

  $existing = Get-NetFirewallHyperVRule -Name $Name -ErrorAction SilentlyContinue
  if ($null -ne $existing) {
    Set-NetFirewallHyperVRule -Name $Name `
      -NewDisplayName $DisplayName `
      -Enabled 'True' `
      -Direction Inbound `
      -Action Allow `
      -VMCreatorId $WslCreatorId `
      -Protocol $Protocol `
      -LocalPorts $LocalPorts | Out-Null
    return
  }

  New-NetFirewallHyperVRule -Name $Name `
    -DisplayName $DisplayName `
    -Enabled 'True' `
    -Direction Inbound `
    -Action Allow `
    -VMCreatorId $WslCreatorId `
    -Protocol $Protocol `
    -LocalPorts $LocalPorts | Out-Null
}

function Configure-HyperVFirewall {
  if ($SkipSystemSetup) {
    Write-Info 'Skipping Hyper-V firewall changes because -SkipSystemSetup is set.'
    return
  }
  if (-not (Test-IsAdministrator)) {
    Stop-Setup 'Configuring inbound access to WSL requires an Administrator PowerShell window.'
  }
  if (-not (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) {
    Stop-Setup 'Hyper-V firewall commands are unavailable. Update Windows 11 and WSL, then try again.'
  }

  Write-Info 'Allowing SSH, Host Helper, and Mosh through the WSL Hyper-V firewall...'
  Ensure-HyperVFirewallRule `
    -Name "Moshline-WSL-SSH-$Port" `
    -DisplayName "Moshline WSL SSH ($Port/TCP)" `
    -Protocol TCP `
    -LocalPorts @([string]$Port)
  Ensure-HyperVFirewallRule `
    -Name "Moshline-WSL-Bridge-$BridgePort" `
    -DisplayName "Moshline WSL Host Helper ($BridgePort/TCP)" `
    -Protocol TCP `
    -LocalPorts @([string]$BridgePort)
  Ensure-HyperVFirewallRule `
    -Name 'Moshline-WSL-Mosh' `
    -DisplayName 'Moshline WSL Mosh (60000-61000/UDP)' `
    -Protocol UDP `
    -LocalPorts @('60000-61000')
}

function Detect-IPv4Address {
  if (-not [string]::IsNullOrWhiteSpace($ServerHost)) {
    return $ServerHost.Trim()
  }

  try {
    $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
      Sort-Object -Property RouteMetric, InterfaceMetric
    foreach ($route in $routes) {
      $candidate = Get-NetIPAddress `
        -AddressFamily IPv4 `
        -InterfaceIndex $route.InterfaceIndex `
        -ErrorAction SilentlyContinue |
        Where-Object {
          $_.IPAddress -ne '127.0.0.1' -and
          $_.IPAddress -notlike '169.254.*'
        } |
        Select-Object -First 1
      if ($null -ne $candidate -and -not [string]::IsNullOrWhiteSpace($candidate.IPAddress)) {
        return $candidate.IPAddress
      }
    }
  } catch {
    return $null
  }
  return $null
}

function Add-WSLEnvironmentNames {
  param([string[]]$Names)

  $entries = @()
  if (-not [string]::IsNullOrWhiteSpace($env:WSLENV)) {
    $entries += $env:WSLENV.Split(':')
  }
  $entries += $Names
  $env:WSLENV = (($entries |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique) -join ':')
}

if ($env:MOSHLINE_SETUP_SOURCE_ONLY -eq '1') {
  return
}

if ($env:OS -ne 'Windows_NT') {
  Stop-Setup 'This script must be run from Windows PowerShell. On Linux or macOS, use quick-setup.sh.'
}

Assert-Port -Label 'SSH port' -Value $Port
Assert-Port -Label 'Host Helper port' -Value $BridgePort

$buildNumber = Get-WindowsBuildNumber
if (-not (Test-IsWindowsWorkstation)) {
  Stop-Setup 'Native Windows Server is not supported. Use a Linux virtual machine or another Linux/macOS host.'
}
if ($buildNumber -lt 22621) {
  Stop-Setup 'Windows support requires Windows 11 22H2 or newer because Moshline uses WSL2 mirrored networking.'
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Stop-Setup "WSL is not available. Open Administrator PowerShell, run 'wsl --install -d Ubuntu', restart Windows, then run this command again."
}

Ensure-CurrentWSL

$installedDistros = @(Get-InstalledDistros)
$resolvedDistro = Resolve-Distro -InstalledDistros $installedDistros
if ([string]::IsNullOrWhiteSpace($resolvedDistro)) {
  if ($SkipSystemSetup) {
    $requestedDistro = if ([string]::IsNullOrWhiteSpace($Distro)) { 'Ubuntu' } else { $Distro }
    Stop-Setup "WSL distribution '$requestedDistro' is not installed. Run 'wsl --install -d $requestedDistro', finish its first-run setup, then try again."
  }
  if (-not (Test-IsAdministrator)) {
    Stop-Setup 'Installing WSL requires an Administrator PowerShell window.'
  }
  $installDistro = if ([string]::IsNullOrWhiteSpace($Distro)) { 'Ubuntu' } else { $Distro }
  Write-Info "Installing WSL2 and $installDistro..."
  & wsl.exe --install -d $installDistro
  if ($LASTEXITCODE -ne 0) {
    Stop-Setup "Unable to install WSL distribution '$installDistro'."
  }
  $installedDistros = @(Get-InstalledDistros)
  $resolvedDistro = Resolve-Distro -InstalledDistros $installedDistros
  if ([string]::IsNullOrWhiteSpace($resolvedDistro)) {
    Stop-Setup 'Finish the Linux first-run setup (and restart Windows if requested), then run this command again.'
  }
}

Ensure-WSL2 -DistroName $resolvedDistro

$networkChanged = Enable-MirroredNetworking
$systemdChanged = Ensure-Systemd -DistroName $resolvedDistro
if ($networkChanged -or $systemdChanged) {
  Write-Info 'Restarting WSL to apply networking and service changes...'
  & wsl.exe --shutdown
  if ($LASTEXITCODE -ne 0) {
    Stop-Setup "Unable to restart WSL. Run 'wsl --shutdown', then try again."
  }
  try {
    $initName = Invoke-WSLText -DistroName $resolvedDistro -CommandArguments @(
      'sh', '-lc', 'ps -p 1 -o comm= | tr -d "[:space:]"'
    )
    if ($initName -ne 'systemd') {
      Stop-Setup "systemd did not start in '$resolvedDistro'. Check /etc/wsl.conf, run 'wsl --shutdown', then try again."
    }
  } catch {
    Stop-Setup "Unable to restart '$resolvedDistro': $($_.Exception.Message)"
  }
}

Configure-HyperVFirewall

$resolvedHost = Detect-IPv4Address
if ([string]::IsNullOrWhiteSpace($resolvedHost)) {
  Stop-Setup 'Unable to detect a LAN address. Re-run with -ServerHost <address>.'
}

$resolvedUser = $User
if ([string]::IsNullOrWhiteSpace($resolvedUser)) {
  try {
    $resolvedUser = Invoke-WSLText -DistroName $resolvedDistro -CommandArguments @('id', '-un')
  } catch {
    Stop-Setup "Unable to detect the Linux username in '$resolvedDistro': $($_.Exception.Message)"
  }
}
$resolvedUser = $resolvedUser.Trim()

$environmentNames = @(
  'MOSHLINE_SETUP_URL',
  'MOSHLINE_SERVER_HOST',
  'MOSHLINE_SERVER_USER',
  'MOSHLINE_SSH_PORT',
  'MOSHLINE_BRIDGE_PORT',
  'MOSHLINE_SKIP_SYSTEM_SETUP',
  'MOSHLINE_NO_BROWSER'
)
if (-not [string]::IsNullOrWhiteSpace($env:NOMAD_PUBKEY_B64)) {
  $environmentNames += 'NOMAD_PUBKEY_B64'
}

$savedEnvironment = @{}
foreach ($name in $environmentNames + @('WSLENV')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
  $env:MOSHLINE_SETUP_URL = $SetupScriptUrl
  $env:MOSHLINE_SERVER_HOST = $resolvedHost
  $env:MOSHLINE_SERVER_USER = $resolvedUser
  $env:MOSHLINE_SSH_PORT = [string]$Port
  $env:MOSHLINE_BRIDGE_PORT = [string]$BridgePort
  $env:MOSHLINE_SKIP_SYSTEM_SETUP = if ($SkipSystemSetup) { '1' } else { '0' }
  $env:MOSHLINE_NO_BROWSER = if ($NoBrowser) { '1' } else { '0' }
  Add-WSLEnvironmentNames -Names $environmentNames

  Write-Info "Running the Linux setup inside WSL2 distribution '$resolvedDistro'..."
  $setupCommand = @'
set -euo pipefail
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$MOSHLINE_SETUP_URL" | bash -s -- \
    --host "$MOSHLINE_SERVER_HOST" \
    --user "$MOSHLINE_SERVER_USER" \
    --port "$MOSHLINE_SSH_PORT" \
    --bridge-port "$MOSHLINE_BRIDGE_PORT" \
    $([ "$MOSHLINE_SKIP_SYSTEM_SETUP" = "1" ] && printf '%s' '--skip-system-setup') \
    $([ "$MOSHLINE_NO_BROWSER" = "1" ] && printf '%s' '--no-browser')
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$MOSHLINE_SETUP_URL" | bash -s -- \
    --host "$MOSHLINE_SERVER_HOST" \
    --user "$MOSHLINE_SERVER_USER" \
    --port "$MOSHLINE_SSH_PORT" \
    --bridge-port "$MOSHLINE_BRIDGE_PORT" \
    $([ "$MOSHLINE_SKIP_SYSTEM_SETUP" = "1" ] && printf '%s' '--skip-system-setup') \
    $([ "$MOSHLINE_NO_BROWSER" = "1" ] && printf '%s' '--no-browser')
else
  echo '[Moshline] curl or wget is required inside WSL.' >&2
  exit 1
fi
'@
  & wsl.exe -d $resolvedDistro -- bash -lc $setupCommand
  if ($LASTEXITCODE -ne 0) {
    Stop-Setup 'The Linux setup inside WSL failed. Fix the error above, then run this command again.'
  }
} finally {
  foreach ($name in $savedEnvironment.Keys) {
    [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
  }
}

Write-Info 'Done. Keep WSL running and scan the QR code shown above in the Moshline app.'
