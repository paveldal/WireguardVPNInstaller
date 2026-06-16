#!/usr/bin/env bash
set -euo pipefail

export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/local/sbin:/usr/sbin:/sbin"

CLIENT_INTERFACE="${CLIENT_INTERFACE:-wg0}"
CHAIN_INTERFACE="${CHAIN_INTERFACE:-wg-exit}"
WG_CONFIG_DIR="${WG_CONFIG_DIR:-/etc/wireguard}"
WG_CHAIN_PREFIX="${WG_CHAIN_PREFIX:-10.77.0}"
WG_ENTRY_IPV4="${WG_ENTRY_IPV4:-${WG_CHAIN_PREFIX}.2}"
WG_EXIT_IPV4="${WG_EXIT_IPV4:-${WG_CHAIN_PREFIX}.1}"
WG_CHAIN_CIDR="${WG_CHAIN_CIDR:-${WG_CHAIN_PREFIX}.0/30}"
WG_CLIENT_CIDR="${WG_CLIENT_CIDR:-}"
WG_EXIT_ENDPOINT="${WG_EXIT_ENDPOINT:-}"
WG_EXIT_PORT="${WG_EXIT_PORT:-51821}"
WG_EXIT_PUBLIC_KEY="${WG_EXIT_PUBLIC_KEY:-}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
ROUTE_TABLE="${ROUTE_TABLE:-51821}"
ROUTE_PRIORITY="${ROUTE_PRIORITY:-100}"
PREPARE_ONLY=0
FORCE=0
ALLOW_DIRECT_FALLBACK=0

usage() {
  cat <<USAGE
Usage:
  sudo $0 --prepare [options]
  sudo $0 --exit-endpoint HOST --exit-public-key KEY [options]

Run this on VPS1, the entry node where normal clients connect.

Workflow:
  1. On VPS1: sudo $0 --prepare
  2. Copy the printed VPS1 chain public key to VPS2.
  3. On VPS2: sudo ./install-exit-node.sh --entry-public-key VPS1_PUBLIC_KEY --endpoint VPS2_PUBLIC_IP_OR_DNS
  4. Copy the printed VPS2 exit public key back to VPS1.
  5. On VPS1: sudo $0 --exit-endpoint VPS2_PUBLIC_IP_OR_DNS --exit-public-key VPS2_PUBLIC_KEY

Options:
  --prepare                Generate/print VPS1 chain key and exit.
  --client-interface NAME  Existing client-facing interface. Default: ${CLIENT_INTERFACE}
  --chain-interface NAME   VPS1->VPS2 interface. Default: ${CHAIN_INTERFACE}
  --chain-prefix A.B.C     /30 chain prefix. Default: ${WG_CHAIN_PREFIX}
  --entry-ip A.B.C.D       VPS1 tunnel IP. Default: <prefix>.2
  --exit-ip A.B.C.D        VPS2 tunnel IP. Default: <prefix>.1
  --client-cidr CIDR       Client network behind VPS1. Default: read from ${CLIENT_INTERFACE}.env
  --exit-endpoint HOST     VPS2 public IP or DNS. Required unless --prepare.
  --exit-port PORT         VPS2 UDP port. Default: ${WG_EXIT_PORT}
  --exit-public-key KEY    VPS2 exit public key. Required unless --prepare.
  --route-table NUMBER     Policy routing table. Default: ${ROUTE_TABLE}
  --route-priority NUMBER  Policy routing rule priority. Default: ${ROUTE_PRIORITY}
  --allow-direct-fallback  Do not install the client egress kill-switch.
  --force                  Backup and replace existing chain config.
  -h, --help               Show this help.
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

valid_number() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 4294967295 ))
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
    --prepare)
      PREPARE_ONLY=1; shift ;;
    --client-interface)
      CLIENT_INTERFACE="${2:-}"; shift 2 ;;
    --chain-interface)
      CHAIN_INTERFACE="${2:-}"; shift 2 ;;
    --chain-prefix)
      WG_CHAIN_PREFIX="${2:-}"; WG_ENTRY_IPV4="${WG_CHAIN_PREFIX}.2"; WG_EXIT_IPV4="${WG_CHAIN_PREFIX}.1"; WG_CHAIN_CIDR="${WG_CHAIN_PREFIX}.0/30"; shift 2 ;;
    --entry-ip)
      WG_ENTRY_IPV4="${2:-}"; shift 2 ;;
    --exit-ip)
      WG_EXIT_IPV4="${2:-}"; shift 2 ;;
    --client-cidr)
      WG_CLIENT_CIDR="${2:-}"; shift 2 ;;
    --exit-endpoint)
      WG_EXIT_ENDPOINT="${2:-}"; shift 2 ;;
    --exit-port)
      WG_EXIT_PORT="${2:-}"; shift 2 ;;
    --exit-public-key)
      WG_EXIT_PUBLIC_KEY="${2:-}"; shift 2 ;;
    --route-table)
      ROUTE_TABLE="${2:-}"; shift 2 ;;
    --route-priority)
      ROUTE_PRIORITY="${2:-}"; shift 2 ;;
    --allow-direct-fallback)
      ALLOW_DIRECT_FALLBACK=1; shift ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      fail "unknown option: $1" ;;
  esac
done

[[ "${CLIENT_INTERFACE}" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || fail "invalid client interface name"
[[ "${CHAIN_INTERFACE}" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || fail "invalid chain interface name"
valid_prefix "${WG_CHAIN_PREFIX}" || fail "--chain-prefix must look like A.B.C"
valid_ipv4 "${WG_ENTRY_IPV4}" || fail "invalid entry IP"
valid_ipv4 "${WG_EXIT_IPV4}" || fail "invalid exit IP"
valid_cidr "${WG_CHAIN_CIDR}" || fail "invalid chain CIDR"
valid_port "${WG_EXIT_PORT}" || fail "invalid exit UDP port"
valid_number "${ROUTE_TABLE}" || fail "invalid route table"
valid_number "${ROUTE_PRIORITY}" || fail "invalid route priority"

require_root
umask 077

command -v wg >/dev/null 2>&1 || fail "missing command: wg"
command -v wg-quick >/dev/null 2>&1 || fail "missing command: wg-quick"
command -v ip >/dev/null 2>&1 || fail "missing command: ip"
command -v iptables >/dev/null 2>&1 || fail "missing command: iptables"

CLIENT_CONF="${WG_CONFIG_DIR}/${CLIENT_INTERFACE}.conf"
CLIENT_ENV="${WG_CONFIG_DIR}/${CLIENT_INTERFACE}.env"
CHAIN_CONF="${WG_CONFIG_DIR}/${CHAIN_INTERFACE}.conf"
KEYS_DIR="${WG_CONFIG_DIR}/keys"
ENTRY_PRIVATE_KEY_FILE="${KEYS_DIR}/${CHAIN_INTERFACE}_entry_private.key"
ENTRY_PUBLIC_KEY_FILE="${KEYS_DIR}/${CHAIN_INTERFACE}_entry_public.key"

[[ -f "${CLIENT_CONF}" ]] || fail "client-facing server config not found: ${CLIENT_CONF}; run install-server.sh on VPS1 first"

if [[ -z "${WG_CLIENT_CIDR}" && -f "${CLIENT_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${CLIENT_ENV}"
  WG_CLIENT_CIDR="${WG_NETWORK_CIDR:-}"
fi
[[ -n "${WG_CLIENT_CIDR}" ]] || fail "client CIDR is unknown; pass --client-cidr"
valid_cidr "${WG_CLIENT_CIDR}" || fail "invalid client CIDR"

mkdir -p "${KEYS_DIR}"
chmod 700 "${WG_CONFIG_DIR}" "${KEYS_DIR}"

if [[ ! -f "${ENTRY_PRIVATE_KEY_FILE}" ]]; then
  wg genkey > "${ENTRY_PRIVATE_KEY_FILE}"
  wg pubkey < "${ENTRY_PRIVATE_KEY_FILE}" > "${ENTRY_PUBLIC_KEY_FILE}"
  chmod 600 "${ENTRY_PRIVATE_KEY_FILE}" "${ENTRY_PUBLIC_KEY_FILE}"
elif [[ ! -f "${ENTRY_PUBLIC_KEY_FILE}" ]]; then
  wg pubkey < "${ENTRY_PRIVATE_KEY_FILE}" > "${ENTRY_PUBLIC_KEY_FILE}"
  chmod 600 "${ENTRY_PUBLIC_KEY_FILE}"
fi

ENTRY_PRIVATE_KEY="$(<"${ENTRY_PRIVATE_KEY_FILE}")"
ENTRY_PUBLIC_KEY="$(<"${ENTRY_PUBLIC_KEY_FILE}")"

if [[ "${PREPARE_ONLY}" -eq 1 ]]; then
  echo "VPS1 chain key prepared."
  echo "Entry public key: ${ENTRY_PUBLIC_KEY}"
  echo "Private key file: ${ENTRY_PRIVATE_KEY_FILE}"
  echo "Run on VPS2: sudo ./install-exit-node.sh --entry-public-key ${ENTRY_PUBLIC_KEY} --endpoint VPS2_PUBLIC_IP_OR_DNS"
  exit 0
fi

[[ -n "${WG_EXIT_ENDPOINT}" ]] || fail "--exit-endpoint is required"
[[ -n "${WG_EXIT_PUBLIC_KEY}" ]] || fail "--exit-public-key is required"

if [[ -f "${CHAIN_CONF}" && "${FORCE}" -ne 1 ]]; then
  fail "${CHAIN_CONF} already exists; use --force to replace it"
fi

if [[ -f "${CHAIN_CONF}" ]]; then
  BACKUP="${CHAIN_CONF}.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -p "${CHAIN_CONF}" "${BACKUP}"
  echo "Existing chain config backed up to ${BACKUP}"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "wg-quick@${CHAIN_INTERFACE}" 2>/dev/null || true
  else
    wg-quick down "${CHAIN_INTERFACE}" 2>/dev/null || true
  fi
fi

cat > "${CHAIN_CONF}" <<CONF
[Interface]
Address = ${WG_ENTRY_IPV4}/30
PrivateKey = ${ENTRY_PRIVATE_KEY}
Table = off
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; ip rule add from ${WG_CLIENT_CIDR} table ${ROUTE_TABLE} priority ${ROUTE_PRIORITY} 2>/dev/null || true; ip route replace ${WG_CLIENT_CIDR} dev ${CLIENT_INTERFACE} table ${ROUTE_TABLE}; ip route replace default dev ${CHAIN_INTERFACE} table ${ROUTE_TABLE}; iptables -A FORWARD -i ${CLIENT_INTERFACE} -o ${CHAIN_INTERFACE} -s ${WG_CLIENT_CIDR} -j ACCEPT; iptables -A FORWARD -i ${CHAIN_INTERFACE} -o ${CLIENT_INTERFACE} -d ${WG_CLIENT_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = ip rule del from ${WG_CLIENT_CIDR} table ${ROUTE_TABLE} priority ${ROUTE_PRIORITY} 2>/dev/null || true; ip route flush table ${ROUTE_TABLE} 2>/dev/null || true; iptables -D FORWARD -i ${CLIENT_INTERFACE} -o ${CHAIN_INTERFACE} -s ${WG_CLIENT_CIDR} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${CHAIN_INTERFACE} -o ${CLIENT_INTERFACE} -d ${WG_CLIENT_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# Exit node: VPS2
[Peer]
PublicKey = ${WG_EXIT_PUBLIC_KEY}
Endpoint = ${WG_EXIT_ENDPOINT}:${WG_EXIT_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${WG_KEEPALIVE}
CONF
chmod 600 "${CHAIN_CONF}"

cat > /etc/sysctl.d/99-wireguard-entry-chain.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
sysctl -w net.ipv4.ip_forward=1 >/dev/null

if command -v systemctl >/dev/null 2>&1; then
  OVERRIDE_DIR="/etc/systemd/system/wg-quick@${CHAIN_INTERFACE}.service.d"
  mkdir -p "${OVERRIDE_DIR}"
  cat > "${OVERRIDE_DIR}/override.conf" <<SYSTEMD
[Unit]
Wants=wg-quick@${CLIENT_INTERFACE}.service
After=wg-quick@${CLIENT_INTERFACE}.service
SYSTEMD
  systemctl daemon-reload
  systemctl enable --now "wg-quick@${CHAIN_INTERFACE}"
else
  wg-quick up "${CHAIN_INTERFACE}"
fi

install_kill_switch() {
  local marker="# Multi-hop kill switch for ${CHAIN_INTERFACE}"
  local post_up="PostUp = iptables -I FORWARD 1 -i ${CLIENT_INTERFACE} -s ${WG_CLIENT_CIDR} ! -d ${WG_CLIENT_CIDR} ! -o ${CHAIN_INTERFACE} -j REJECT"
  local post_down="PostDown = iptables -D FORWARD -i ${CLIENT_INTERFACE} -s ${WG_CLIENT_CIDR} ! -d ${WG_CLIENT_CIDR} ! -o ${CHAIN_INTERFACE} -j REJECT 2>/dev/null || true"

  if ! grep -Fqx "${marker}" "${CLIENT_CONF}"; then
    KILL_BACKUP="${CLIENT_CONF}.bak.$(date -u +%Y%m%d%H%M%S)"
    cp -p "${CLIENT_CONF}" "${KILL_BACKUP}"
    {
      echo
      echo "${marker}"
      echo "${post_up}"
      echo "${post_down}"
    } >> "${CLIENT_CONF}"
    chmod 600 "${CLIENT_CONF}"
    echo "Client-facing config backed up before kill-switch edit: ${KILL_BACKUP}"
  fi

  if ! iptables -C FORWARD -i "${CLIENT_INTERFACE}" -s "${WG_CLIENT_CIDR}" ! -d "${WG_CLIENT_CIDR}" ! -o "${CHAIN_INTERFACE}" -j REJECT 2>/dev/null; then
    iptables -I FORWARD 1 -i "${CLIENT_INTERFACE}" -s "${WG_CLIENT_CIDR}" ! -d "${WG_CLIENT_CIDR}" ! -o "${CHAIN_INTERFACE}" -j REJECT
  fi
}

if [[ "${ALLOW_DIRECT_FALLBACK}" -ne 1 ]]; then
  install_kill_switch
fi

echo "Entry chain configured."
echo "Role: VPS1 / client entry"
echo "Client-facing interface: ${CLIENT_INTERFACE}"
echo "Chain interface: ${CHAIN_INTERFACE}"
echo "VPS2 endpoint: ${WG_EXIT_ENDPOINT}:${WG_EXIT_PORT}"
echo "Client network routed through VPS2: ${WG_CLIENT_CIDR}"
echo "Entry public key: ${ENTRY_PUBLIC_KEY}"
echo "Chain config: ${CHAIN_CONF}"
if [[ "${ALLOW_DIRECT_FALLBACK}" -eq 1 ]]; then
  echo "Kill-switch: disabled; clients may fall back to direct VPS1 egress if the chain is down."
else
  echo "Kill-switch: enabled; clients are blocked from direct VPS1 egress when not going to ${CHAIN_INTERFACE}."
fi
