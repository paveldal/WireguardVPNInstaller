#!/usr/bin/env bash
set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_CONFIG_DIR="${WG_CONFIG_DIR:-/etc/wireguard}"
CLIENT_NAME=""
DELETE_FILES=0

usage() {
  cat <<USAGE
Usage: sudo $0 CLIENT_NAME [options]

Options:
  --interface NAME       WireGuard interface name. Default: ${WG_INTERFACE}
  --config-dir PATH      WireGuard config directory. Default: ${WG_CONFIG_DIR}
  --delete-files         Delete client files instead of moving them to _removed.
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
    --delete-files)
      DELETE_FILES=1; shift ;;
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

SERVER_CONF="${WG_CONFIG_DIR}/${WG_INTERFACE}.conf"
SERVER_ENV="${WG_CONFIG_DIR}/${WG_INTERFACE}.env"
[[ -f "${SERVER_CONF}" ]] || fail "server config not found: ${SERVER_CONF}"
[[ -f "${SERVER_ENV}" ]] || fail "server env not found: ${SERVER_ENV}"

# shellcheck disable=SC1090
source "${SERVER_ENV}"

WG_CLIENTS_DIR="${WG_CLIENTS_DIR:-${WG_CONFIG_DIR}/clients}"
WG_STATE_FILE="${WG_STATE_FILE:-${WG_CONFIG_DIR}/${WG_INTERFACE}.clients}"
[[ -f "${WG_STATE_FILE}" ]] || fail "state file not found: ${WG_STATE_FILE}"

LOCK_DIR="${WG_CONFIG_DIR}/.${WG_INTERFACE}.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  fail "another WireGuard change appears to be running: ${LOCK_DIR}"
fi
trap 'rmdir "${LOCK_DIR}"' EXIT

CLIENT_LINE="$(awk -F '\t' -v name="${CLIENT_NAME}" '$1 == name {print; found=1; exit} END {exit found ? 0 : 1}' "${WG_STATE_FILE}")" || fail "client not found: ${CLIENT_NAME}"
CLIENT_IP="$(printf '%s' "${CLIENT_LINE}" | awk -F '\t' '{print $2}')"
CLIENT_PUBLIC_KEY="$(printf '%s' "${CLIENT_LINE}" | awk -F '\t' '{print $3}')"

BACKUP="${SERVER_CONF}.bak.$(date -u +%Y%m%d%H%M%S)"
cp -p "${SERVER_CONF}" "${BACKUP}"

TMP_CONF="${SERVER_CONF}.tmp.$$"
awk -v name="${CLIENT_NAME}" -v key="${CLIENT_PUBLIC_KEY}" '
  $0 == "# Client: " name {skip=1; next}
  skip && $0 ~ /^# Created: / {next}
  skip && $0 == "[Peer]" {next}
  skip && $0 == "PublicKey = " key {next}
  skip && $0 ~ /^PresharedKey = / {next}
  skip && $0 ~ /^AllowedIPs = / {next}
  skip && $0 == "" {skip=0; next}
  {print}
' "${SERVER_CONF}" > "${TMP_CONF}"
if grep -q "^PublicKey = ${CLIENT_PUBLIC_KEY}$" "${TMP_CONF}"; then
  rm -f "${TMP_CONF}"
  fail "could not find and remove peer block for ${CLIENT_NAME} in ${SERVER_CONF}"
fi
mv "${TMP_CONF}" "${SERVER_CONF}"
chmod 600 "${SERVER_CONF}"

if command -v ip >/dev/null 2>&1 && ip link show "${WG_INTERFACE}" >/dev/null 2>&1; then
  if ! wg syncconf "${WG_INTERFACE}" <(wg-quick strip "${WG_INTERFACE}"); then
    cp -p "${BACKUP}" "${SERVER_CONF}"
    fail "failed to apply WireGuard config; restored ${SERVER_CONF} from ${BACKUP}"
  fi
fi

TMP_STATE="${WG_STATE_FILE}.tmp.$$"
awk -F '\t' -v name="${CLIENT_NAME}" '$1 != name' "${WG_STATE_FILE}" > "${TMP_STATE}"
mv "${TMP_STATE}" "${WG_STATE_FILE}"
chmod 600 "${WG_STATE_FILE}"

CLIENT_DIR="${WG_CLIENTS_DIR}/${CLIENT_NAME}"
if [[ -d "${CLIENT_DIR}" ]]; then
  if [[ "${DELETE_FILES}" -eq 1 ]]; then
    rm -rf "${CLIENT_DIR}"
    echo "Client files deleted: ${CLIENT_DIR}"
  else
    REMOVED_DIR="${WG_CLIENTS_DIR}/_removed/${CLIENT_NAME}-$(date -u +%Y%m%d%H%M%S)"
    mkdir -p "$(dirname "${REMOVED_DIR}")"
    mv "${CLIENT_DIR}" "${REMOVED_DIR}"
    chmod -R go-rwx "${WG_CLIENTS_DIR}/_removed" 2>/dev/null || true
    echo "Client files moved to: ${REMOVED_DIR}"
  fi
fi

echo "Client removed: ${CLIENT_NAME}"
echo "Client IP was: ${CLIENT_IP}"
echo "Server config backup: ${BACKUP}"
