# WireGuard VPN Installer

Scripts for installing a WireGuard IPv4 VPN server and managing clients on Linux/Unix and Windows Server.

The default client profile is a full-tunnel profile:

```text
AllowedIPs = 0.0.0.0/0
```

This sends Internet traffic through the VPN server. The client's directly connected local network is not intentionally blocked: local LAN routes are normally more specific than `0.0.0.0/0` and continue to win in the OS routing table.

## Layout

```text
scripts/
  unix/
    install-server.sh
    add-client.sh
    list-clients.sh
    remove-client.sh
    configure-entry-chain.sh
    install-exit-node.sh
  windows/
    install-server.ps1
    add-client.ps1
    list-clients.ps1
    remove-client.ps1
```

## Linux/Unix Quick Start

Run on the VPN server as root:

```bash
chmod +x scripts/unix/*.sh
sudo scripts/unix/install-server.sh --endpoint YOUR_PUBLIC_IP_OR_DNS
sudo scripts/unix/add-client.sh alice
```

Generated files are stored under:

```text
/etc/wireguard/
  wg0.conf
  wg0.env
  wg0.clients
  keys/
  clients/
    alice/
      alice.conf
      private.key
      public.key
      preshared.key
```

Show a QR code for mobile clients if `qrencode` is installed:

```bash
qrencode -t ansiutf8 < /etc/wireguard/clients/alice/alice.conf
```

Useful defaults:

```text
Interface: wg0
UDP port: 51820
VPN network: 10.8.0.0/24
Server VPN IP: 10.8.0.1
Client AllowedIPs: 0.0.0.0/0
DNS in client config: 1.1.1.1, 1.0.0.1
```

Override examples:

```bash
sudo scripts/unix/install-server.sh --endpoint vpn.example.com --port 51820 --vpn-prefix 10.44.0
sudo scripts/unix/add-client.sh phone --dns "1.1.1.1, 8.8.8.8"
sudo scripts/unix/list-clients.sh
sudo scripts/unix/remove-client.sh phone
```

If the server is behind NAT, always pass `--endpoint` with the public IP or DNS name clients can reach.

## Linux Multi-Hop Chain

Use this when clients should go through two VPS hosts:

```text
client -> VPS1 entry -> VPS2 exit -> Internet
```

VPS1 is the normal server created by `install-server.sh`. Clients still connect only to VPS1. VPS2 is the exit node that performs NAT to the real Internet.

Default chain values:

```text
Client network on VPS1: 10.8.0.0/24
Chain interface: wg-exit
Chain network: 10.77.0.0/30
VPS2 chain IP: 10.77.0.1
VPS1 chain IP: 10.77.0.2
VPS2 UDP port: 51821
```

Workflow:

```bash
# 1. On VPS1, prepare the VPS1 chain key.
sudo scripts/unix/configure-entry-chain.sh --prepare

# 2. Copy the printed "Entry public key" to VPS2.
# On VPS2, install the exit node.
sudo scripts/unix/install-exit-node.sh --entry-public-key VPS1_ENTRY_PUBLIC_KEY --endpoint VPS2_PUBLIC_IP_OR_DNS

# 3. Copy the printed "Exit public key" back to VPS1.
# On VPS1, route client traffic through VPS2.
sudo scripts/unix/configure-entry-chain.sh --exit-endpoint VPS2_PUBLIC_IP_OR_DNS --exit-public-key VPS2_EXIT_PUBLIC_KEY
```

The VPS1 script uses policy routing, so only traffic from the client VPN network is sent to VPS2. VPS1's own SSH/package manager traffic keeps using the normal VPS1 route.

By default, VPS1 also installs a client egress kill-switch. If the VPS1 -> VPS2 tunnel is down, clients are blocked from falling back to direct VPS1 Internet egress. To allow direct fallback, pass:

```bash
sudo scripts/unix/configure-entry-chain.sh --exit-endpoint VPS2_PUBLIC_IP_OR_DNS --exit-public-key VPS2_EXIT_PUBLIC_KEY --allow-direct-fallback
```

Useful checks:

```bash
sudo wg show
ip rule
ip route show table 51821
sudo iptables -S FORWARD
```

## Windows Server Quick Start

Run PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\windows\install-server.ps1 -Endpoint YOUR_PUBLIC_IP_OR_DNS
.\scripts\windows\add-client.ps1 -Name alice
```

Generated files are stored under:

```text
C:\ProgramData\WireGuardVPNInstaller\
  server\
    wg0.conf
    settings.json
    server_private.key
    server_public.key
  clients\
    clients.json
    alice\
      alice.conf
      private.key
      public.key
      preshared.key
```

The Windows installer script configures:

- WireGuard tunnel service using the generated server config.
- Windows Firewall inbound UDP rule.
- IPv4 forwarding registry setting.
- `New-NetNat` for `10.8.0.0/24` when available.

Windows NAT behavior depends on Windows edition and network role. Linux is the recommended target for simple VPS deployments.

## Security Notes

- Private keys are not printed to the console.
- Linux files are created with restrictive permissions.
- Windows data directory permissions are restricted to `Administrators` and `SYSTEM` where possible.
- Server config is backed up before client changes.
- Client names are limited to letters, digits, `_`, and `-`.

## Commands

Linux:

```bash
sudo scripts/unix/install-server.sh --help
sudo scripts/unix/add-client.sh --help
sudo scripts/unix/list-clients.sh
sudo scripts/unix/remove-client.sh alice
sudo scripts/unix/configure-entry-chain.sh --help
sudo scripts/unix/install-exit-node.sh --help
```

Windows:

```powershell
.\scripts\windows\install-server.ps1 -Help
.\scripts\windows\add-client.ps1 -Help
.\scripts\windows\list-clients.ps1
.\scripts\windows\remove-client.ps1 -Name alice
```
