#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:MOSHLINE_SETUP_SOURCE_ONLY = '1'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'quick-setup.ps1')

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )
  if (-not $Condition) {
    throw $Message
  }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "moshline-wslconfig-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
  $Distro = ''
  $resolvedDistro = Resolve-Distro -InstalledDistros @('docker-desktop', 'Ubuntu')
  Assert-True ($resolvedDistro -eq 'Ubuntu') 'Expected setup to ignore Docker utility distributions by default.'

  $configPath = Join-Path $testRoot '.wslconfig'
  Set-Content -LiteralPath $configPath -Value @'
[experimental]
networkingMode=nat

[wsl2]
memory=8GB
'@

  $changed = Enable-MirroredNetworking -ConfigPath $configPath
  $content = Get-Content -LiteralPath $configPath -Raw
  Assert-True $changed 'Expected the WSL configuration to change.'
  Assert-True ($content -match '(?ms)^\[experimental\].*?^networkingMode=nat\r?$') 'An unrelated section was modified.'
  Assert-True ($content -match '(?ms)^\[wsl2\]\r?\nnetworkingMode=mirrored\r?\nmemory=8GB\r?$') 'Mirrored mode was not inserted under [wsl2].'

  $beforeSecondRun = $content
  $changedAgain = Enable-MirroredNetworking -ConfigPath $configPath
  $afterSecondRun = Get-Content -LiteralPath $configPath -Raw
  Assert-True (-not $changedAgain) 'Expected mirrored networking setup to be idempotent.'
  Assert-True ($beforeSecondRun -eq $afterSecondRun) 'The idempotent run rewrote the configuration.'
} finally {
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item Env:MOSHLINE_SETUP_SOURCE_ONLY -ErrorAction SilentlyContinue
}

Write-Host 'PASS: PowerShell quick setup tests'
