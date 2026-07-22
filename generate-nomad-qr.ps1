#requires -Version 5.1

param(
  [string]$ServerHost,
  [string]$User,
  [int]$Port = 22,
  [int]$BridgePort = 24000,
  [string]$Distro,
  [switch]$Auto,
  [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '[Moshline] Windows pairing requires WSL2 because the app starts a Mosh session.'
Write-Host '[Moshline] Redirecting to the supported Windows quick setup...'

$quickSetupUrl = if ([string]::IsNullOrWhiteSpace($env:MOSHLINE_WINDOWS_SETUP_URL)) {
  'https://raw.githubusercontent.com/NomadShell/Scripts/main/quick-setup.ps1'
} else {
  $env:MOSHLINE_WINDOWS_SETUP_URL.Trim()
}
$temporaryScript = Join-Path ([IO.Path]::GetTempPath()) "moshline-quick-setup-$([Guid]::NewGuid()).ps1"

try {
  Invoke-WebRequest -UseBasicParsing -Uri $quickSetupUrl -OutFile $temporaryScript

  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', $temporaryScript,
    '-Port', [string]$Port,
    '-BridgePort', [string]$BridgePort
  )
  if (-not [string]::IsNullOrWhiteSpace($ServerHost)) {
    $arguments += @('-ServerHost', $ServerHost.Trim())
  }
  if (-not [string]::IsNullOrWhiteSpace($User)) {
    $arguments += @('-User', $User.Trim())
  }
  if (-not [string]::IsNullOrWhiteSpace($Distro)) {
    $arguments += @('-Distro', $Distro.Trim())
  }
  if ($NoBrowser) {
    $arguments += '-NoBrowser'
  }

  # -Auto is retained for compatibility; quick setup detects the address by default.
  & powershell.exe @arguments
  $exitCode = $LASTEXITCODE
} finally {
  Remove-Item -LiteralPath $temporaryScript -Force -ErrorAction SilentlyContinue
}

exit $exitCode
