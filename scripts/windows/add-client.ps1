[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Name = "",
    [string]$BaseDir = "C:\ProgramData\WireGuardVPNInstaller",
    [string]$Dns = "",
    [string]$AllowedIPs = "",
    [string]$Endpoint = "",
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    @"
Usage: .\add-client.ps1 -Name CLIENT_NAME [options]

Options:
  -Name CLIENT_NAME      Client name. Letters, digits, _ and - only.
  -BaseDir PATH          Data directory. Default: C:\ProgramData\WireGuardVPNInstaller
  -Dns LIST              Override DNS in generated client config.
  -AllowedIPs LIST       Override client AllowedIPs. Default from server: 0.0.0.0/0
  -Endpoint HOST         Override endpoint written to generated client config.
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

function Get-WireGuardPaths {
    $programFiles = ${env:ProgramFiles}
    [pscustomobject]@{
        WgExe = Join-Path $programFiles "WireGuard\wg.exe"
        WireGuardExe = Join-Path $programFiles "WireGuard\wireguard.exe"
    }
}

function Read-Clients([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    if (-not $raw.Trim()) {
        return @()
    }
    $items = $raw | ConvertFrom-Json
    if ($null -eq $items) {
        return @()
    }
    return @($items)
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
if (-not (Test-Path -LiteralPath $SettingsFile)) {
    Fail "Server settings not found: $SettingsFile. Run install-server.ps1 first."
}
$settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json

$InterfaceName = $settings.InterfaceName
$ServerConfig = Join-Path $ServerDir "$InterfaceName.conf"
$ServerPublicKeyFile = Join-Path $ServerDir "server_public.key"
$ClientsFile = Join-Path $ClientsDir "clients.json"
if (-not (Test-Path -LiteralPath $ServerConfig)) {
    Fail "Server config not found: $ServerConfig."
}

$paths = Get-WireGuardPaths
if (-not (Test-Path -LiteralPath $paths.WgExe)) {
    Fail "wg.exe not found. Install WireGuard for Windows."
}

$clients = Read-Clients -Path $ClientsFile
if ($clients | Where-Object { $_.Name -eq $Name }) {
    Fail "Client already exists: $Name."
}

$clientDir = Join-Path $ClientsDir $Name
if (Test-Path -LiteralPath $clientDir) {
    Fail "Client directory already exists: $clientDir."
}
New-Item -ItemType Directory -Path $clientDir -Force | Out-Null

$usedIps = @($clients | ForEach-Object { $_.Ip })
$serverLast = [int]($settings.ServerVpnIp.ToString().Split('.')[-1])
$clientIp = $null
for ($i = 2; $i -le 254; $i++) {
    if ($i -eq $serverLast) {
        continue
    }
    $candidate = "$($settings.VpnPrefix).$i"
    if ($usedIps -notcontains $candidate) {
        $clientIp = $candidate
        break
    }
}
if (-not $clientIp) {
    Fail "No free client IPs in $($settings.NetworkCidr)."
}

$clientPrivateKey = (& $paths.WgExe genkey).Trim()
$clientPublicKey = ($clientPrivateKey | & $paths.WgExe pubkey).Trim()
$clientPresharedKey = (& $paths.WgExe genpsk).Trim()
$serverPublicKey = (Get-Content -LiteralPath $ServerPublicKeyFile -Raw).Trim()

$clientPrivateKeyFile = Join-Path $clientDir "private.key"
$clientPublicKeyFile = Join-Path $clientDir "public.key"
$clientPresharedKeyFile = Join-Path $clientDir "preshared.key"
$clientConfig = Join-Path $clientDir "$Name.conf"

Set-Content -LiteralPath $clientPrivateKeyFile -Value $clientPrivateKey -NoNewline
Set-Content -LiteralPath $clientPublicKeyFile -Value $clientPublicKey -NoNewline
Set-Content -LiteralPath $clientPresharedKeyFile -Value $clientPresharedKey -NoNewline

$dnsValue = if ($Dns) { $Dns } else { $settings.Dns }
$allowedValue = if ($AllowedIPs) { $AllowedIPs } else { $settings.ClientAllowedIPs }
$endpointValue = if ($Endpoint) { $Endpoint } else { $settings.Endpoint }

$clientConfigContent = @"
[Interface]
PrivateKey = $clientPrivateKey
Address = $clientIp/32
DNS = $dnsValue

[Peer]
PublicKey = $serverPublicKey
PresharedKey = $clientPresharedKey
Endpoint = $endpointValue`:$($settings.Port)
AllowedIPs = $allowedValue
PersistentKeepalive = $($settings.KeepAlive)
"@
Set-Content -LiteralPath $clientConfig -Value $clientConfigContent -NoNewline

$backup = "$ServerConfig.bak.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
Copy-Item -LiteralPath $ServerConfig -Destination $backup

$peerBlock = @"

# Client: $Name
# Created: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
[Peer]
PublicKey = $clientPublicKey
PresharedKey = $clientPresharedKey
AllowedIPs = $clientIp/32
"@
Add-Content -LiteralPath $ServerConfig -Value $peerBlock

$newClient = [pscustomobject]@{
    Name = $Name
    Ip = $clientIp
    PublicKey = $clientPublicKey
    CreatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Config = $clientConfig
}

$serviceName = "WireGuardTunnel`$$InterfaceName"
try {
    Restart-Service -Name $serviceName -Force
}
catch {
    Copy-Item -LiteralPath $backup -Destination $ServerConfig -Force
    Remove-Item -LiteralPath $clientDir -Recurse -Force -ErrorAction SilentlyContinue
    throw "Failed to restart $serviceName. Restored server config from $backup. Original error: $($_.Exception.Message)"
}

@($clients + $newClient) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ClientsFile

Write-Host "Client added: $Name"
Write-Host "Client IP: $clientIp"
Write-Host "Client config: $clientConfig"
Write-Host "Public key: $clientPublicKey"
Write-Host "Server config backup: $backup"
Write-Host "QR: import $clientConfig in the WireGuard mobile app, or generate a QR code with an external qrencode tool."
