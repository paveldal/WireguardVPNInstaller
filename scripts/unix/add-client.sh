#!/usr/bin/env bash
set -euo pipefail

export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/local/sbin:/usr/sbin:/sbin"

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_CONFIG_DIR="${WG_CONFIG_DIR:-/etc/wireguard}"
WG_DNS_OVERRIDE=""
WG_ALLOWED_IPS_OVERRIDE=""
WG_ENDPOINT_OVERRIDE=""
CLIENT_NAME=""

usage() {
  cat <<USAGE
Usage: sudo $0 CLIENT_NAME [options]

Options:
  --interface NAME       WireGuard interface name. Default: ${WG_INTERFACE}
  --config-dir PATH      WireGuard config directory. Default: ${WG_CONFIG_DIR}
  --dns LIST             Override DNS in generated client config.
  --allowed-ips LIST     Override client AllowedIPs. Default from server: 0.0.0.0/0
  --endpoint HOST        Override endpoint written to generated client config.
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

validate_client_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail "client name must match ^[A-Za-z0-9_-]{1,64}$"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface)
      WG_INTERFACE="${2:-}"; shift 2 ;;
    --config-dir)
      WG_CONFIG_DIR="${2:-}"; shift 2 ;;
    --dns)
      WG_DNS_OVERRIDE="${2:-}"; shift 2 ;;
    --allowed-ips)
      WG_ALLOWED_IPS_OVERRIDE="${2:-}"; shift 2 ;;
    --endpoint)
      WG_ENDPOINT_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    --*)
      fail "unknown option: $1" ;;
    *)
      if [[ -n "${CLIENT_NAME}" ]]; then
        fail "only one client name can be provided"
      fi
      CLIENT_NAME="$1"
      shift ;;
  esac
done

[[ -n "${CLIENT_NAME}" ]] || { usage; exit 1; }
validate_client_name "${CLIENT_NAME}"
require_root
umask 077

SERVER_CONF="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
SERVER_ENV="${WG_CONFIG_DIR}/${WG_INTERFACE}.env"
[[ -f "${SERVER_CONF}" ]] || fail "server config not found: ${SERVER_CONF}"
[[ -f "${SERVER_ENV}" ]] || fail "server env not found: ${SERVER_ENV}; run install-server.sh first"

# shellcheck disable=SC1090
source "${SERVER_ENV}"

WG_DNS="${WG_DNS_OVERRIDE:-${WG_DNS}}"
WG_CLIENT_ALLOWED_IPS="${WG_ALLOWED_IPS_OVERRIDE:-${WG_CLIENT_ALLOWED_IPS}}"
WG_ENDPOINT="${WG_ENDPOINT_OVERRIDE:-${WG_ENDPOINT}}"
WG_CLIENTS_DIR="${WG_CLIENTS_DIR:-${WG_CONFIG_DIR}/clients}"
WG_STATE_FILE="${WG_STATE_FILE:-${WG_CONFIG_DIR}/${WG_INTERFACE}.clients}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"

[[ -n "${WG_ENDPOINT}" ]] || fail "endpoint is empty; pass --endpoint"
command -v wg >/dev/null 2>&1 || fail "missing command: wg"
command -v wg-quick >/dev/null 2>&1 || fail "missing command: wg-quick"
command -v ip >/dev/null 2>&1 || fail "missing command: ip"

LOCK_DIR="${WG_CONFIG_DIR}/.${WG_INTERFACE}.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  fail "another WireGuard change appears to be running: ${LOCK_DIR}"
fi
trap 'rmdir "${LOCK_DIR}"' EXIT

CLIENT_DIR="${WG_CLIENTS_DIR}/${CLIENT_NAME}"
[[ ! -e "${CLIENT_DIR}" ]] || fail "client already exists: ${CLIENT_NAME}"
if [[ -f "${WG_STATE_FILE}" ]] && awk -F '\t' -v name="${CLIENT_NAME}" '$1 == name {found=1} END {exit found ? 0 : 1}' "${WG_STATE_FILE}"; then
  fail "client already exists in state file: ${CLIENT_NAME}"
fi

mkdir -p "${CLIENT_DIR}"
chmod 700 "${CLIENT_DIR}"
touch "${WG_STATE_FILE}"
chmod 600 "${WG_STATE_FILE}"

ip_in_use() {
  local ip="$1"
  local conf
  if awk -F '\t' -v ip="${ip}" '$2 == ip {found=1} END {exit found ? 0 : 1}' "${WG_STATE_FILE}" 2>/dev/null; then
    return 0
  fi
  shopt -s nullglob
  for conf in "${WG_CLIENTS_DIR}"/*/*.conf; do
    if grep -q "^Address = ${ip}/32$" "${conf}"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

next_client_ip() {
  local server_last="${WG_SERVER_IPV4##*.}"
  local i ip
  for i in $(seq 2 254); do
    [[ "${i}" == "${server_last}" ]] && continue
    ip="${WG_IPV4_PREFIX}.${i}"
    if ! ip_in_use "${ip}"; then
      echo "${ip}"
      return 0
    fi
  done
  return 1
}

CLIENT_IP="$(next_client_ip)" || fail "no free client IPs in ${WG_NETWORK_CIDR}"

CLIENT_PRIVATE_KEY_FILE="${CLIENT_DIR}/private.key"
CLIENT_PUBLIC_KEY_FILE="${CLIENT_DIR}/public.key"
CLIENT_PRESHARED_KEY_FILE="${CLIENT_DIR}/preshared.key"
CLIENT_CONFIG="${CLIENT_DIR}/${CLIENT_NAME}.conf"

wg genkey > "${CLIENT_PRIVATE_KEY_FILE}"
wg pubkey < "${CLIENT_PRIVATE_KEY_FILE}" > "${CLIENT_PUBLIC_KEY_FILE}"
wg genpsk > "${CLIENT_PRESHARED_KEY_FILE}"
chmod 600 "${CLIENT_PRIVATE_KEY_FILE}" "${CLIENT_PUBLIC_KEY_FILE}" "${CLIENT_PRESHARED_KEY_FILE}"

CLIENT_PRIVATE_KEY="$(<"${CLIENT_PRIVATE_KEY_FILE}")"
CLIENT_PUBLIC_KEY="$(<"${CLIENT_PUBLIC_KEY_FILE}")"
CLIENT_PRESHARED_KEY="$(<"${CLIENT_PRESHARED_KEY_FILE}")"
SERVER_PUBLIC_KEY="$(<"${WG_CONFIG_DIR}/keys/server_public.key")"

cat > "${CLIENT_CONFIG}" <<CONF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
DNS = ${WG_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
Endpoint = ${WG_ENDPOINT}:${WG_PORT}
AllowedIPs = ${WG_CLIENT_ALLOWED_IPS}
PersistentKeepalive = ${WG_KEEPALIVE}
CONF
chmod 600 "${CLIENT_CONFIG}"

BACKUP="${SERVER_CONF}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "${SERVER_CONF}" "${BACKUP}"

{
  echo
  echo "# Client: ${CLIENT_NAME}"
  echo "# Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[Peer]"
  echo "PublicKey = ${CLIENT_PUBLIC_KEY}"
  echo "PresharedKey = ${CLIENT_PRESHARED_KEY}"
  echo "AllowedIPs = ${CLIENT_IP}/32"
} >> "${SERVER_CONF}"

if ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
  if ! wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}"); then
    cp -p "${BACKUP}" "${SERVER_CONF}"
    rm -rf "${CLIENT_DIR}"
    fail "failed to apply WireGuard config; restored ${SERVER_CONF} from ${BACKUP}"
  fi
fi

printf '%s\t%s\t%s\t%s\n' "${CLIENT_NAME}" "${CLIENT_IP}" "${CLIENT_PUBLIC_KEY}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${WG_STATE_FILE}"

echo "Client added: ${CLIENT_NAME}"
echo "Client IP: ${CLIENT_IP}"
echo "Client config: ${CLIENT_CONFIG}"
echo "Public key: ${CLIENT_PUBLIC_KEY}"
echo "Server config backup: ${BACKUP}"
if command -v qrencode >/dev/null 2>&1; then
  echo "Show QR: qrencode -t ansiutf8 < ${CLIENT_CONFIG}"
else
  echo "QR: install qrencode, then run: qrencode -t ansiutf8 < ${CLIENT_CONFIG}"
fi
