[CmdletBinding()]
param(
    [string]$BaseDir = "C:\ProgramData\WireGuardVPNInstaller",
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    @"
Usage: .\list-clients.ps1 [options]

Options:
  -BaseDir PATH          Data directory. Default: C:\ProgramData\WireGuardVPNInstaller
"@ | Write-Host
    exit 0
}

$SettingsFile = Join-Path (Join-Path $BaseDir "server") "settings.json"
$ClientsFile = Join-Path (Join-Path $BaseDir "clients") "clients.json"

if (-not (Test-Path -LiteralPath $ClientsFile)) {
    Write-Host "No clients found."
    Write-Host "Clients file: $ClientsFile"
    exit 0
}

$raw = Get-Content -LiteralPath $ClientsFile -Raw
if (-not $raw.Trim()) {
    Write-Host "No clients found."
    exit 0
}

$clients = @($raw | ConvertFrom-Json)
if (-not $clients) {
    Write-Host "No clients found."
    exit 0
}

$clients | Sort-Object Name | Format-Table Name, Ip, PublicKey, CreatedUtc, Config -AutoSize

if (Test-Path -LiteralPath $SettingsFile) {
    $settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
    $wgExe = Join-Path ${env:ProgramFiles} "WireGuard\wg.exe"
    if (Test-Path -LiteralPath $wgExe) {
        Write-Host ""
        Write-Host "Live WireGuard status:"
        & $wgExe show $settings.InterfaceName latest-handshakes transfer
    }
}
