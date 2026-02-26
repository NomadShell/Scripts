param(
  [string]$ServerHost,
  [string]$User,
  [int]$Port = 22,
  [switch]$SkipSystemSetup,
  [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info {
  param([string]$Message)
  Write-Host "[Nomad] $Message"
}

function Ensure-OpenSSHServer {
  if ($SkipSystemSetup) {
    Info "Skipping OpenSSH setup because -SkipSystemSetup is set."
    return
  }

  try {
    if (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) {
      $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
      if ($capability -and $capability.State -ne 'Installed') {
        Info "Installing OpenSSH Server..."
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
      }
    } else {
      Info "Get-WindowsCapability is unavailable. Install OpenSSH Server manually if needed."
    }
  } catch {
    Info "OpenSSH Server install step skipped: $($_.Exception.Message)"
  }

  try {
    $service = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($null -eq $service) {
      Info "sshd service was not found. Install OpenSSH Server first."
      return
    }
    if ($service.StartType -ne 'Automatic') {
      Set-Service -Name 'sshd' -StartupType Automatic
    }
    if ($service.Status -ne 'Running') {
      Info "Starting sshd service..."
      Start-Service -Name 'sshd'
    }
  } catch {
    Info "Unable to start sshd automatically: $($_.Exception.Message)"
  }
}

function Decode-PublicKey {
  param([string]$Base64Data)
  if ([string]::IsNullOrWhiteSpace($Base64Data)) {
    return $null
  }
  try {
    $bytes = [Convert]::FromBase64String($Base64Data.Trim())
    return [Text.Encoding]::UTF8.GetString($bytes).Trim("`r", "`n")
  } catch {
    return $null
  }
}

function Add-PublicKeyIfProvided {
  $pubKeyB64 = $env:NOMAD_PUBKEY_B64
  if ([string]::IsNullOrWhiteSpace($pubKeyB64)) {
    return
  }

  $pubKey = Decode-PublicKey -Base64Data $pubKeyB64
  if ([string]::IsNullOrWhiteSpace($pubKey)) {
    Info "Unable to decode NOMAD_PUBKEY_B64."
    return
  }

  $sshDir = Join-Path $HOME '.ssh'
  $authorizedKeys = Join-Path $sshDir 'authorized_keys'

  if (-not (Test-Path -Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
  }
  if (-not (Test-Path -Path $authorizedKeys)) {
    New-Item -ItemType File -Path $authorizedKeys -Force | Out-Null
  }

  $existing = @()
  try {
    $existing = Get-Content -Path $authorizedKeys -ErrorAction Stop
  } catch {
    $existing = @()
  }

  if ($existing -contains $pubKey) {
    Info "SSH public key already exists in $authorizedKeys"
    return
  }

  Add-Content -Path $authorizedKeys -Value $pubKey
  Info "Added SSH public key to $authorizedKeys"
}

function Detect-IPv4Address {
  if (-not [string]::IsNullOrWhiteSpace($ServerHost)) {
    return $ServerHost.Trim()
  }

  try {
    $routes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
      Sort-Object -Property RouteMetric, InterfaceMetric
    foreach ($route in $routes) {
      $candidate = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
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
    # Fall through to ipconfig parsing.
  }

  try {
    $ipconfigOutput = ipconfig
    foreach ($line in $ipconfigOutput) {
      if ($line -match 'IPv4 Address[^\:]*:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)') {
        return $Matches[1]
      }
    }
  } catch {
    return $null
  }

  return $null
}

function Resolve-UserName {
  if (-not [string]::IsNullOrWhiteSpace($User)) {
    return $User.Trim()
  }
  if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
    return $env:USERNAME
  }
  return (whoami)
}

function Build-Payload {
  param(
    [string]$PayloadHost,
    [string]$PayloadUser,
    [int]$PayloadPort,
    [string]$Token
  )

  $parts = @(
    'host=' + [Uri]::EscapeDataString($PayloadHost),
    'port=' + [Uri]::EscapeDataString([string]$PayloadPort),
    'user=' + [Uri]::EscapeDataString($PayloadUser),
    'mosh=true',
    'setup_token=' + [Uri]::EscapeDataString($Token)
  )
  return 'nomad://connect?' + ($parts -join '&')
}

Ensure-OpenSSHServer
Add-PublicKeyIfProvided

$resolvedHost = Detect-IPv4Address
if ([string]::IsNullOrWhiteSpace($resolvedHost)) {
  Info "Unable to detect a LAN IP. Re-run with -ServerHost <ip>."
  exit 1
}

$resolvedUser = Resolve-UserName
$token = [Guid]::NewGuid().ToString()
$payload = Build-Payload -PayloadHost $resolvedHost -PayloadUser $resolvedUser -PayloadPort $Port -Token $token

Info "Quick setup payload:"
Write-Output $payload

$encodedPayload = [Uri]::EscapeDataString($payload)
$qrUrl = "https://api.qrserver.com/v1/create-qr-code/?size=320x320&data=$encodedPayload"
Info "QR URL:"
Write-Output $qrUrl

if (-not $NoBrowser) {
  try {
    Start-Process $qrUrl | Out-Null
  } catch {
    Info "Unable to open browser automatically: $($_.Exception.Message)"
  }
}

Info "Done. Scan the generated QR code from the Nomad app."
