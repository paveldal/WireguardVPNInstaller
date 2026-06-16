#!/usr/bin/env bash
set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_IPV4_PREFIX="${WG_IPV4_PREFIX:-10.8.0}"
WG_SERVER_IPV4="${WG_SERVER_IPV4:-${WG_IPV4_PREFIX}.1}"
WG_NETWORK_CIDR="${WG_NETWORK_CIDR:-${WG_IPV4_PREFIX}.0/24}"
WG_DNS="${WG_DNS:-1.1.1.1, 1.0.0.1}"
WG_CLIENT_ALLOWED_IPS="${WG_CLIENT_ALLOWED_IPS:-0.0.0.0/0}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
WG_CONFIG_DIR="${WG_CONFIG_DIR:-/etc/wireguard}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
WG_WAN_INTERFACE="${WG_WAN_INTERFACE:-}"
FORCE=0

usage() {
  cat <<USAGE
Usage: sudo $0 [options]

Options:
  --interface NAME       WireGuard interface name. Default: ${WG_INTERFACE}
  --port PORT            UDP listen port. Default: ${WG_PORT}
  --vpn-prefix A.B.C     /24 VPN prefix. Default: ${WG_IPV4_PREFIX}
  --server-ip A.B.C.D    Server VPN IP. Default: <prefix>.1
  --endpoint HOST        Public IP or DNS clients will use.
  --dns LIST             DNS value written to client configs. Default: ${WG_DNS}
  --wan-interface NAME   Outbound interface for NAT. Auto-detected by default.
  --force                Backup and replace existing server config.
  -h, --help             Show this help.

Environment variables with the same names as the defaults can also be used.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface)
      WG_INTERFACE="${2:-}"; shift 2 ;;
    --port)
      WG_PORT="${2:-}"; shift 2 ;;
    --vpn-prefix)
      WG_IPV4_PREFIX="${2:-}"; WG_SERVER_IPV4="${WG_IPV4_PREFIX}.1"; WG_NETWORK_CIDR="${WG_IPV4_PREFIX}.0/24"; shift 2 ;;
    --server-ip)
      WG_SERVER_IPV4="${2:-}"; shift 2 ;;
    --endpoint)
      WG_ENDPOINT="${2:-}"; shift 2 ;;
    --dns)
      WG_DNS="${2:-}"; shift 2 ;;
    --wan-interface)
      WG_WAN_INTERFACE="${2:-}"; shift 2 ;;
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
valid_prefix "${WG_IPV4_PREFIX}" || fail "--vpn-prefix must look like A.B.C"
[[ "${WG_SERVER_IPV4}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "invalid server IP"

SERVER_CONF="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
SERVER_ENV="${WG_CONFIG_DIR}/${WG_INTERFACE}.env"
STATE_FILE="${WG_CONFIG_DIR}/${WG_INTERFACE}.clients"
KEYS_DIR="${WG_CONFIG_DIR}/keys"
CLIENTS_DIR="${WG_CONFIG_DIR}/clients"

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iptables
    dnf install -y qrencode || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wireguard-tools iptables
    yum install -y qrencode || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --needed --noconfirm wireguard-tools iptables
    pacman -Sy --needed --noconfirm qrencode || true
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install wireguard-tools iptables
    zypper --non-interactive install qrencode || true
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache wireguard-tools wireguard-tools-wg-quick iptables
    apk add --no-cache qrencode || true
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

shell_quote_env() {
  local name="$1"
  local value="$2"
  printf '%s=%q\n' "${name}" "${value}"
}

write_server_env() {
  {
    shell_quote_env WG_INTERFACE "${WG_INTERFACE}"
    shell_quote_env WG_PORT "${WG_PORT}"
    shell_quote_env WG_IPV4_PREFIX "${WG_IPV4_PREFIX}"
    shell_quote_env WG_SERVER_IPV4 "${WG_SERVER_IPV4}"
    shell_quote_env WG_NETWORK_CIDR "${WG_NETWORK_CIDR}"
    shell_quote_env WG_DNS "${WG_DNS}"
    shell_quote_env WG_CLIENT_ALLOWED_IPS "${WG_CLIENT_ALLOWED_IPS}"
    shell_quote_env WG_KEEPALIVE "${WG_KEEPALIVE}"
    shell_quote_env WG_ENDPOINT "${WG_ENDPOINT}"
    shell_quote_env WG_CONFIG_DIR "${WG_CONFIG_DIR}"
    shell_quote_env WG_CLIENTS_DIR "${CLIENTS_DIR}"
    shell_quote_env WG_STATE_FILE "${STATE_FILE}"
  } > "${SERVER_ENV}"
  chmod 600 "${SERVER_ENV}"
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

mkdir -p "${KEYS_DIR}" "${CLIENTS_DIR}"
chmod 700 "${WG_CONFIG_DIR}" "${KEYS_DIR}" "${CLIENTS_DIR}"

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

SERVER_PRIVATE_KEY_FILE="${KEYS_DIR}/server_private.key"
SERVER_PUBLIC_KEY_FILE="${KEYS_DIR}/server_public.key"

wg genkey > "${SERVER_PRIVATE_KEY_FILE}"
wg pubkey < "${SERVER_PRIVATE_KEY_FILE}" > "${SERVER_PUBLIC_KEY_FILE}"
chmod 600 "${SERVER_PRIVATE_KEY_FILE}" "${SERVER_PUBLIC_KEY_FILE}"

SERVER_PRIVATE_KEY="$(<"${SERVER_PRIVATE_KEY_FILE}")"

cat > "${SERVER_CONF}" <<CONF
[Interface]
Address = ${WG_SERVER_IPV4}/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
SaveConfig = false
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -t nat -A POSTROUTING -s ${WG_NETWORK_CIDR} -o ${WAN_INTERFACE} -j MASQUERADE; iptables -A FORWARD -i ${WG_INTERFACE} -o ${WAN_INTERFACE} -j ACCEPT; iptables -A FORWARD -i ${WAN_INTERFACE} -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NETWORK_CIDR} -o ${WAN_INTERFACE} -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i ${WG_INTERFACE} -o ${WAN_INTERFACE} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${WAN_INTERFACE} -o ${WG_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
CONF
chmod 600 "${SERVER_CONF}"

write_server_env
touch "${STATE_FILE}"
chmod 600 "${STATE_FILE}"

cat > /etc/sysctl.d/99-wireguard-vpn.conf <<SYSCTL
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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "WireGuard server installed."
echo "Interface: ${WG_INTERFACE}"
echo "Endpoint: ${WG_ENDPOINT}:${WG_PORT}"
echo "VPN network: ${WG_NETWORK_CIDR}"
echo "Server config: ${SERVER_CONF}"
echo "Clients directory: ${CLIENTS_DIR}"
echo "Add a client: sudo ${SCRIPT_DIR}/add-client.sh alice"
if command -v qrencode >/dev/null 2>&1; then
  echo "QR support: installed"
else
  echo "QR support: qrencode not installed; client configs are still generated"
fi
