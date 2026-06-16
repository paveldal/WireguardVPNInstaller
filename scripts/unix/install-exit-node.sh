#!/usr/bin/env bash
set -euo pipefail

export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/local/sbin:/usr/sbin:/sbin"

WG_INTERFACE="${WG_INTERFACE:-wg-exit}"
WG_PORT="${WG_PORT:-51821}"
WG_CONFIG_DIR="${WG_CONFIG_DIR:-/etc/wireguard}"
WG_CHAIN_PREFIX="${WG_CHAIN_PREFIX:-10.77.0}"
WG_EXIT_IPV4="${WG_EXIT_IPV4:-${WG_CHAIN_PREFIX}.1}"
WG_ENTRY_IPV4="${WG_ENTRY_IPV4:-${WG_CHAIN_PREFIX}.2}"
WG_CHAIN_CIDR="${WG_CHAIN_CIDR:-${WG_CHAIN_PREFIX}.0/30}"
WG_ENTRY_CLIENT_CIDR="${WG_ENTRY_CLIENT_CIDR:-10.8.0.0/24}"
WG_ENTRY_PUBLIC_KEY="${WG_ENTRY_PUBLIC_KEY:-}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
WG_WAN_INTERFACE="${WG_WAN_INTERFACE:-}"
REPLACE_CLIENT_ROUTE=0
FORCE=0

usage() {
  cat <<USAGE
Usage: sudo $0 --entry-public-key KEY [options]

Run this on VPS2, the exit node that sends traffic to the real Internet.

Options:
  --entry-public-key KEY Entry/VPS1 chain public key. Required.
  --interface NAME       WireGuard chain interface. Default: ${WG_INTERFACE}
  --port PORT            UDP listen port on VPS2. Default: ${WG_PORT}
  --chain-prefix A.B.C   /30 chain prefix. Default: ${WG_CHAIN_PREFIX}
  --exit-ip A.B.C.D      VPS2 tunnel IP. Default: <prefix>.1
  --entry-ip A.B.C.D     VPS1 tunnel IP. Default: <prefix>.2
  --client-cidr CIDR     Client network behind VPS1. Default: ${WG_ENTRY_CLIENT_CIDR}
  --endpoint HOST        Public IP or DNS of VPS2, printed for VPS1 command.
  --wan-interface NAME   Outbound interface for NAT. Auto-detected by default.
  --replace-client-route Replace an existing route to the VPS1 client CIDR.
  --force                Backup and replace existing chain config.
  -h, --help             Show this help.
USAGE
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "run as root"
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_prefix() {
  [[ "$1" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]
}

valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

valid_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry-public-key)
      WG_ENTRY_PUBLIC_KEY="${2:-}"; shift 2 ;;
    --interface)
      WG_INTERFACE="${2:-}"; shift 2 ;;
    --port)
      WG_PORT="${2:-}"; shift 2 ;;
    --chain-prefix)
      WG_CHAIN_PREFIX="${2:-}"; WG_EXIT_IPV4="${WG_CHAIN_PREFIX}.1"; WG_ENTRY_IPV4="${WG_CHAIN_PREFIX}.2"; WG_CHAIN_CIDR="${WG_CHAIN_PREFIX}.0/30"; shift 2 ;;
    --exit-ip)
      WG_EXIT_IPV4="${2:-}"; shift 2 ;;
    --entry-ip)
      WG_ENTRY_IPV4="${2:-}"; shift 2 ;;
    --client-cidr)
      WG_ENTRY_CLIENT_CIDR="${2:-}"; shift 2 ;;
    --endpoint)
      WG_ENDPOINT="${2:-}"; shift 2 ;;
    --wan-interface)
      WG_WAN_INTERFACE="${2:-}"; shift 2 ;;
    --replace-client-route)
      REPLACE_CLIENT_ROUTE=1; shift ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail "unknown option: $1" ;;
  esac
done

[[ "${WG_INTERFACE}" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || fail "invalid interface name"
valid_port "${WG_PORT}" || fail "invalid UDP port"
valid_prefix "${WG_CHAIN_PREFIX}" || fail "--chain-prefix must look like A.B.C"
valid_ipv4 "${WG_EXIT_IPV4}" || fail "invalid exit IP"
valid_ipv4 "${WG_ENTRY_IPV4}" || fail "invalid entry IP"
valid_cidr "${WG_CHAIN_CIDR}" || fail "invalid chain CIDR"
valid_cidr "${WG_ENTRY_CLIENT_CIDR}" || fail "invalid client CIDR"
[[ -n "${WG_ENTRY_PUBLIC_KEY}" ]] || fail "--entry-public-key is required"

SERVER_CONF="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
KEYS_DIR="${WG_CONFIG_DIR}/keys"
EXIT_PRIVATE_KEY_FILE="${KEYS_DIR}/${WG_INTERFACE}_exit_private.key"
EXIT_PUBLIC_KEY_FILE="${KEYS_DIR}/${WG_INTERFACE}_exit_public.key"

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iptables
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wireguard-tools iptables
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --needed --noconfirm wireguard-tools iptables
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install wireguard-tools iptables
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache wireguard-tools wireguard-tools-wg-quick iptables
  else
    fail "unsupported package manager; install wireguard-tools, wg-quick and iptables manually"
  fi
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

detect_default_iface() {
  if [[ -n "${WG_WAN_INTERFACE}" ]]; then
    echo "${WG_WAN_INTERFACE}"
    return
  fi
  ip -4 route list default 0.0.0.0/0 2>/dev/null | awk '{print $5; exit}'
}

detect_endpoint() {
  if [[ -n "${WG_ENDPOINT}" ]]; then
    echo "${WG_ENDPOINT}"
    return
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsS --max-time 8 https://api.ipify.org && return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -4 -qO- --timeout=8 https://api.ipify.org && return
  fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

require_root
umask 077

install_packages
need_command wg
need_command wg-quick
need_command ip
need_command iptables
need_command awk

WAN_INTERFACE="$(detect_default_iface)"
[[ -n "${WAN_INTERFACE}" ]] || fail "could not detect outbound interface; pass --wan-interface"

WG_ENDPOINT="$(detect_endpoint)"
[[ -n "${WG_ENDPOINT}" ]] || fail "could not detect public endpoint; pass --endpoint"

EXISTING_CLIENT_ROUTE="$(ip -4 route show "${WG_ENTRY_CLIENT_CIDR}" 2>/dev/null | awk 'NR == 1 {print; exit}')"
if [[ -n "${EXISTING_CLIENT_ROUTE}" && "${EXISTING_CLIENT_ROUTE}" != *" dev ${WG_INTERFACE}"* && "${REPLACE_CLIENT_ROUTE}" -ne 1 ]]; then
  fail "route ${WG_ENTRY_CLIENT_CIDR} already exists: ${EXISTING_CLIENT_ROUTE}. This is usually VPS1 or another local VPN. Run this script on VPS2, or pass --replace-client-route if replacing that route is intentional."
fi

mkdir -p "${KEYS_DIR}"
chmod 700 "${WG_CONFIG_DIR}" "${KEYS_DIR}"

if [[ -f "${SERVER_CONF}" && "${FORCE}" -ne 1 ]]; then
  fail "${SERVER_CONF} already exists; use --force to replace it"
fi

if [[ -f "${SERVER_CONF}" ]]; then
  BACKUP="${SERVER_CONF}.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -p "${SERVER_CONF}" "${BACKUP}"
  echo "Existing config backed up to ${BACKUP}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
  else
    wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
  fi
fi

wg genkey > "${EXIT_PRIVATE_KEY_FILE}"
wg pubkey < "${EXIT_PRIVATE_KEY_FILE}" > "${EXIT_PUBLIC_KEY_FILE}"
chmod 600 "${EXIT_PRIVATE_KEY_FILE}" "${EXIT_PUBLIC_KEY_FILE}"

EXIT_PRIVATE_KEY="$(<"${EXIT_PRIVATE_KEY_FILE}")"
EXIT_PUBLIC_KEY="$(<"${EXIT_PUBLIC_KEY_FILE}")"

cat > "${SERVER_CONF}" <<CONF
[Interface]
Address = ${WG_EXIT_IPV4}/30
ListenPort = ${WG_PORT}
PrivateKey = ${EXIT_PRIVATE_KEY}
SaveConfig = false
Table = off
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; ip route replace ${WG_ENTRY_CLIENT_CIDR} dev ${WG_INTERFACE}; iptables -t nat -A POSTROUTING -s ${WG_ENTRY_CLIENT_CIDR} -o ${WAN_INTERFACE} -j MASQUERADE; iptables -t nat -A POSTROUTING -s ${WG_CHAIN_CIDR} -o ${WAN_INTERFACE} -j MASQUERADE; iptables -A FORWARD -i ${WG_INTERFACE} -o ${WAN_INTERFACE} -s ${WG_ENTRY_CLIENT_CIDR} -j ACCEPT; iptables -A FORWARD -i ${WG_INTERFACE} -o ${WAN_INTERFACE} -s ${WG_CHAIN_CIDR} -j ACCEPT; iptables -A FORWARD -i ${WAN_INTERFACE} -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = ip route del ${WG_ENTRY_CLIENT_CIDR} dev ${WG_INTERFACE} 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${WG_ENTRY_CLIENT_CIDR} -o ${WAN_INTERFACE} -j MASQUERADE 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${WG_CHAIN_CIDR} -o ${WAN_INTERFACE} -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i ${WG_INTERFACE} -o ${WAN_INTERFACE} -s ${WG_ENTRY_CLIENT_CIDR} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${WG_INTERFACE} -o ${WAN_INTERFACE} -s ${WG_CHAIN_CIDR} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${WAN_INTERFACE} -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# Entry node: VPS1
[Peer]
PublicKey = ${WG_ENTRY_PUBLIC_KEY}
AllowedIPs = ${WG_ENTRY_IPV4}/32, ${WG_ENTRY_CLIENT_CIDR}
CONF
chmod 600 "${SERVER_CONF}"

cat > /etc/sysctl.d/99-wireguard-exit-node.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
sysctl -w net.ipv4.ip_forward=1 >/dev/null

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  ufw allow "${WG_PORT}/udp" || true
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --add-port="${WG_PORT}/udp" --permanent || true
  firewall-cmd --reload || true
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now "wg-quick@${WG_INTERFACE}"
else
  wg-quick up "${WG_INTERFACE}"
fi

echo "WireGuard exit node installed."
echo "Role: VPS2 / exit to real Internet"
echo "Interface: ${WG_INTERFACE}"
echo "Endpoint for VPS1: ${WG_ENDPOINT}:${WG_PORT}"
echo "Chain network: ${WG_CHAIN_CIDR}"
echo "Entry client network routed through this exit: ${WG_ENTRY_CLIENT_CIDR}"
echo "Exit public key: ${EXIT_PUBLIC_KEY}"
echo "Server config: ${SERVER_CONF}"
echo "Run on VPS1: sudo ./configure-entry-chain.sh --exit-endpoint ${WG_ENDPOINT} --exit-port ${WG_PORT} --exit-public-key ${EXIT_PUBLIC_KEY}"
