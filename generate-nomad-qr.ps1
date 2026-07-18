param(
  [string]$ServerHost,
  [string]$User,
  [int]$Port = 22,
  [switch]$Auto,
  [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
  param([string]$Message)
  Write-Host "[Moshline] $Message"
}

function Detect-IPv4Address {
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

Write-Info 'Legacy terminal-only pairing: Host Helper, Inbox, and Usages are not configured.'

if ([string]::IsNullOrWhiteSpace($ServerHost) -and $Auto) {
  $ServerHost = Detect-IPv4Address
}
if ([string]::IsNullOrWhiteSpace($ServerHost)) {
  Write-Info 'Missing -ServerHost. Use -ServerHost <ip> or -Auto.'
  exit 1
}
if ([string]::IsNullOrWhiteSpace($User)) {
  $User = if ([string]::IsNullOrWhiteSpace($env:USERNAME)) { whoami } else { $env:USERNAME }
}

$token = [Guid]::NewGuid().ToString()
$payload = Build-Payload -PayloadHost $ServerHost.Trim() -PayloadUser $User.Trim() -PayloadPort $Port -Token $token

Write-Info 'QR payload:'
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
