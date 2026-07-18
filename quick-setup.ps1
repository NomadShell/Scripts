param(
  [string]$ServerHost,
  [string]$User,
  [int]$Port = 22,
  [switch]$SkipSystemSetup,
  [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
  param([string]$Message)
  Write-Host "[Moshline] $Message"
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-OpenSSHServer {
  if ($SkipSystemSetup) {
    Write-Info 'Skipping OpenSSH setup because -SkipSystemSetup is set.'
    return
  }

  try {
    if (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) {
      $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
      if ($capability -and $capability.State -ne 'Installed') {
        Write-Info 'Installing OpenSSH Server...'
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
      }
    } else {
      Write-Info 'Get-WindowsCapability is unavailable. Install OpenSSH Server manually if needed.'
    }
  } catch {
    Write-Info "OpenSSH Server install step skipped: $($_.Exception.Message)"
  }

  try {
    $service = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    if ($null -eq $service) {
      Write-Info 'sshd service was not found. Install OpenSSH Server first.'
      return
    }
    if ($service.StartType -ne 'Automatic') {
      Set-Service -Name 'sshd' -StartupType Automatic
    }
    if ($service.Status -ne 'Running') {
      Write-Info 'Starting sshd service...'
      Start-Service -Name 'sshd'
    }
  } catch {
    Write-Info "Unable to start sshd automatically: $($_.Exception.Message)"
  }

  try {
    $firewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($null -eq $firewallRule) {
      New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort $Port | Out-Null
    } elseif ($firewallRule.Enabled -ne 'True') {
      Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
    }
  } catch {
    Write-Info "Unable to configure the SSH firewall rule automatically: $($_.Exception.Message)"
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

function Resolve-AuthorizedKeysPath {
  if ((Test-IsAdministrator) -and -not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
    return Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
  }
  return Join-Path (Join-Path $HOME '.ssh') 'authorized_keys'
}

function Add-PublicKeyIfProvided {
  $pubKeyB64 = $env:NOMAD_PUBKEY_B64
  if ([string]::IsNullOrWhiteSpace($pubKeyB64)) {
    return
  }

  $pubKey = Decode-PublicKey -Base64Data $pubKeyB64
  if ([string]::IsNullOrWhiteSpace($pubKey)) {
    Write-Info 'Unable to decode NOMAD_PUBKEY_B64.'
    return
  }

  $authorizedKeys = Resolve-AuthorizedKeysPath
  $sshDir = Split-Path -Parent $authorizedKeys
  if (-not (Test-Path -LiteralPath $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $authorizedKeys)) {
    New-Item -ItemType File -Path $authorizedKeys -Force | Out-Null
  }

  $existing = @(Get-Content -LiteralPath $authorizedKeys -ErrorAction SilentlyContinue)
  if ($existing -notcontains $pubKey) {
    Add-Content -LiteralPath $authorizedKeys -Value $pubKey
    Write-Info "Added SSH public key to $authorizedKeys"
  } else {
    Write-Info "SSH public key already exists in $authorizedKeys"
  }

  if ($authorizedKeys -like '*\administrators_authorized_keys') {
    try {
      & icacls.exe $authorizedKeys /inheritance:r /grant '*S-1-5-18:F' /grant '*S-1-5-32-544:F' | Out-Null
    } catch {
      Write-Info "Unable to tighten administrators_authorized_keys permissions: $($_.Exception.Message)"
    }
  }
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
    foreach ($line in (ipconfig)) {
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
  Write-Info 'Unable to detect a LAN IP. Re-run with -ServerHost <ip>.'
  exit 1
}

$resolvedUser = Resolve-UserName
$token = [Guid]::NewGuid().ToString()
$payload = Build-Payload -PayloadHost $resolvedHost -PayloadUser $resolvedUser -PayloadPort $Port -Token $token

Write-Info 'Quick setup payload:'
Write-Output $payload

$encodedPayload = [Uri]::EscapeDataString($payload)
$qrUrl = "https://api.qrserver.com/v1/create-qr-code/?size=320x320&data=$encodedPayload"
Write-Info 'QR URL:'
Write-Output $qrUrl

if (-not $NoBrowser) {
  try {
    Start-Process $qrUrl | Out-Null
  } catch {
    Write-Info "Unable to open the QR code automatically: $($_.Exception.Message)"
  }
}

Write-Info 'Done. Scan the generated QR code from the Moshline app.'
