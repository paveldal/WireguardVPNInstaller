[CmdletBinding()]
param(
    [string]$InterfaceName = "wg0",
    [int]$Port = 51820,
    [string]$VpnPrefix = "10.8.0",
    [string]$ServerVpnIp = "",
    [string]$Endpoint = "",
    [string]$Dns = "1.1.1.1, 1.0.0.1",
    [string]$BaseDir = "C:\ProgramData\WireGuardVPNInstaller",
    [switch]$Force,
    [switch]$SkipInstall,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    @"
Usage: .\install-server.ps1 [options]

Options:
  -InterfaceName NAME    WireGuard interface name. Default: wg0
  -Port PORT             UDP listen port. Default: 51820
  -VpnPrefix A.B.C       /24 VPN prefix. Default: 10.8.0
  -ServerVpnIp A.B.C.D   Server VPN IP. Default: <prefix>.1
  -Endpoint HOST         Public IP or DNS clients will use.
  -Dns LIST              DNS value written to client configs.
  -BaseDir PATH          Data directory. Default: C:\ProgramData\WireGuardVPNInstaller
  -Force                 Backup and replace existing server config.
  -SkipInstall           Do not try to download/install WireGuard.
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
    $candidates = @(
        (Join-Path $programFiles "WireGuard\wg.exe"),
        (Join-Path $programFiles "WireGuard\wireguard.exe")
    )
    $wgExe = $candidates | Where-Object { Split-Path $_ -Leaf | Where-Object { $_ -eq "wg.exe" } } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $wireGuardExe = $candidates | Where-Object { Split-Path $_ -Leaf | Where-Object { $_ -eq "wireguard.exe" } } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    [pscustomobject]@{
        WgExe = $wgExe
        WireGuardExe = $wireGuardExe
    }
}

function Install-WireGuardIfNeeded {
    if ($SkipInstall) {
        return
    }

    $paths = Get-WireGuardPaths
    if ($paths.WgExe -and $paths.WireGuardExe) {
        return
    }

    $installer = Join-Path $env:TEMP "wireguard-installer.exe"
    Write-Host "WireGuard not found. Downloading official installer..."
    Invoke-WebRequest -Uri "https://download.wireguard.com/windows-client/wireguard-installer.exe" -OutFile $installer -UseBasicParsing
    Start-Process -FilePath $installer -ArgumentList "/quiet" -Wait
}

function Get-PublicEndpoint {
    if ($Endpoint) {
        return $Endpoint
    }
    try {
        return (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 8).Trim()
    }
    catch {
        $ip = Get-NetIPConfiguration |
            Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
            Select-Object -ExpandProperty IPv4Address -First 1 |
            Select-Object -ExpandProperty IPAddress -First 1
        return $ip
    }
}

function Protect-Directory([string]$Path) {
    & icacls $Path /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" | Out-Null
}

if (-not (Test-Admin)) {
    Fail "Run PowerShell as Administrator."
}

if ($InterfaceName -notmatch '^[A-Za-z0-9_.-]{1,32}$') {
    Fail "Invalid interface name."
}
if ($Port -lt 1 -or $Port -gt 65535) {
    Fail "Invalid UDP port."
}
if ($VpnPrefix -notmatch '^([0-9]{1,3}\.){2}[0-9]{1,3}$') {
    Fail "-VpnPrefix must look like A.B.C."
}
if (-not $ServerVpnIp) {
    $ServerVpnIp = "$VpnPrefix.1"
}

$NetworkCidr = "$VpnPrefix.0/24"
$ServerDir = Join-Path $BaseDir "server"
$ClientsDir = Join-Path $BaseDir "clients"
$ServerConfig = Join-Path $ServerDir "$InterfaceName.conf"
$SettingsFile = Join-Path $ServerDir "settings.json"
$PrivateKeyFile = Join-Path $ServerDir "server_private.key"
$PublicKeyFile = Join-Path $ServerDir "server_public.key"

Install-WireGuardIfNeeded
$paths = Get-WireGuardPaths
if (-not $paths.WgExe -or -not $paths.WireGuardExe) {
    Fail "WireGuard was not found. Install WireGuard for Windows or rerun without -SkipInstall."
}

New-Item -ItemType Directory -Path $ServerDir -Force | Out-Null
New-Item -ItemType Directory -Path $ClientsDir -Force | Out-Null
Protect-Directory -Path $BaseDir

if ((Test-Path -LiteralPath $ServerConfig) -and -not $Force) {
    Fail "$ServerConfig already exists. Use -Force to replace it."
}

if (Test-Path -LiteralPath $ServerConfig) {
    $backup = "$ServerConfig.bak.$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
    Copy-Item -LiteralPath $ServerConfig -Destination $backup
    Write-Host "Existing config backed up to $backup"
    & $paths.WireGuardExe /uninstalltunnelservice $InterfaceName 2>$null | Out-Null
}

$privateKey = (& $paths.WgExe genkey).Trim()
$publicKey = ($privateKey | & $paths.WgExe pubkey).Trim()
Set-Content -LiteralPath $PrivateKeyFile -Value $privateKey -NoNewline
Set-Content -LiteralPath $PublicKeyFile -Value $publicKey -NoNewline

$serverConfigContent = @"
[Interface]
PrivateKey = $privateKey
Address = $ServerVpnIp/24
ListenPort = $Port
"@
Set-Content -LiteralPath $ServerConfig -Value $serverConfigContent -NoNewline

$resolvedEndpoint = Get-PublicEndpoint
if (-not $resolvedEndpoint) {
    Fail "Could not detect public endpoint. Pass -Endpoint."
}

$settings = [ordered]@{
    InterfaceName = $InterfaceName
    Port = $Port
    VpnPrefix = $VpnPrefix
    ServerVpnIp = $ServerVpnIp
    NetworkCidr = $NetworkCidr
    Dns = $Dns
    Endpoint = $resolvedEndpoint
    ClientAllowedIPs = "0.0.0.0/0"
    KeepAlive = 25
    BaseDir = $BaseDir
    ClientsDir = $ClientsDir
}
$settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $SettingsFile

$clientsFile = Join-Path $ClientsDir "clients.json"
if (-not (Test-Path -LiteralPath $clientsFile)) {
    Set-Content -LiteralPath $clientsFile -Value "[]"
}

New-NetFirewallRule -DisplayName "WireGuard VPN UDP $Port" -Direction Inbound -Protocol UDP -LocalPort $Port -Action Allow -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name IPEnableRouter -Value 1

try {
    $existingNat = Get-NetNat -Name "WireGuardVPNInstaller" -ErrorAction SilentlyContinue
    if (-not $existingNat) {
        New-NetNat -Name "WireGuardVPNInstaller" -InternalIPInterfaceAddressPrefix $NetworkCidr | Out-Null
    }
}
catch {
    Write-Host "Warning: New-NetNat is not available or failed. Configure NAT manually if clients have no Internet access."
}

& $paths.WireGuardExe /installtunnelservice $ServerConfig | Out-Null
$serviceName = "WireGuardTunnel`$$InterfaceName"
Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue

Write-Host "WireGuard server installed."
Write-Host "Interface: $InterfaceName"
Write-Host "Endpoint: $resolvedEndpoint`:$Port"
Write-Host "VPN network: $NetworkCidr"
Write-Host "Server config: $ServerConfig"
Write-Host "Clients directory: $ClientsDir"
Write-Host "Add a client: .\scripts\windows\add-client.ps1 -Name alice"
