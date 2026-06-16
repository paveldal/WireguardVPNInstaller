[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Name = "",
    [string]$BaseDir = "C:\ProgramData\WireGuardVPNInstaller",
    [switch]$DeleteFiles,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    @"
Usage: .\remove-client.ps1 -Name CLIENT_NAME [options]

Options:
  -Name CLIENT_NAME      Client name to remove.
  -BaseDir PATH          Data directory. Default: C:\ProgramData\WireGuardVPNInstaller
  -DeleteFiles           Delete client files instead of moving them to _removed.
"@ | Write-Host
    exit 0
}

function Fail([string]$Message) {
    throw $Message
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Fail "Run PowerShell as Administrator."
}
if (-not $Name) {
    Fail "Pass -Name CLIENT_NAME."
}
if ($Name -notmatch '^[A-Za-z0-9_-]{1,64}$') {
    Fail "Client name must match ^[A-Za-z0-9_-]{1,64}$."
}

$ServerDir = Join-Path $BaseDir "server"
$ClientsDir = Join-Path $BaseDir "clients"
$SettingsFile = Join-Path $ServerDir "settings.json"
$ClientsFile = Join-Path $ClientsDir "clients.json"

if (-not (Test-Path -LiteralPath $SettingsFile)) {
    Fail "Server settings not found: $SettingsFile."
}
if (-not (Test-Path -LiteralPath $ClientsFile)) {
    Fail "Clients file not found: $ClientsFile."
}

$settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
$clients = @(Get-Content -LiteralPath $ClientsFile -Raw | ConvertFrom-Json)
$client = $clients | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
if (-not $client) {
    Fail "Client not found: $Name."
}

$ServerConfig = Join-Path $ServerDir "$($settings.InterfaceName).conf"
if (-not (Test-Path -LiteralPath $ServerConfig)) {
    Fail "Server config not found: $ServerConfig."
}

$backup = "$ServerConfig.bak.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
Copy-Item -LiteralPath $ServerConfig -Destination $backup

$content = Get-Content -LiteralPath $ServerConfig -Raw
$escapedName = [regex]::Escape($Name)
$escapedKey = [regex]::Escape($client.PublicKey)
$pattern = "(?ms)\r?\n# Client: $escapedName\r?\n# Created: .*?\r?\n\[Peer\]\r?\nPublicKey = $escapedKey\r?\nPresharedKey = .*?\r?\nAllowedIPs = .*?(?=\r?\n# Client:|\z)"
$newContent = [regex]::Replace($content, $pattern, "")
if ($newContent -eq $content) {
    Fail "Could not find the peer block for $Name in $ServerConfig. No changes were applied."
}
Set-Content -LiteralPath $ServerConfig -Value $newContent -NoNewline

$serviceName = "WireGuardTunnel`$$($settings.InterfaceName)"
try {
    Restart-Service -Name $serviceName -Force
}
catch {
    Copy-Item -LiteralPath $backup -Destination $ServerConfig -Force
    throw "Failed to restart $serviceName. Restored server config from $backup. Original error: $($_.Exception.Message)"
}

@($clients | Where-Object { $_.Name -ne $Name }) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ClientsFile

$clientDir = Join-Path $ClientsDir $Name
if (Test-Path -LiteralPath $clientDir) {
    if ($DeleteFiles) {
        Remove-Item -LiteralPath $clientDir -Recurse -Force
        Write-Host "Client files deleted: $clientDir"
    }
    else {
        $removedRoot = Join-Path $ClientsDir "_removed"
        New-Item -ItemType Directory -Path $removedRoot -Force | Out-Null
        $removedDir = Join-Path $removedRoot "$Name-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
        Move-Item -LiteralPath $clientDir -Destination $removedDir
        Write-Host "Client files moved to: $removedDir"
    }
}

Write-Host "Client removed: $Name"
Write-Host "Client IP was: $($client.Ip)"
Write-Host "Server config backup: $backup"
