#!/usr/bin/env bash
set -euo pipefail

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_CONFIG_DIR="${WG_CONFIG_DIR:-/etc/wireguard}"

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --interface NAME       WireGuard interface name. Default: ${WG_INTERFACE}
  --config-dir PATH      WireGuard config directory. Default: ${WG_CONFIG_DIR}
  -h, --help             Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface)
      WG_INTERFACE="${2:-}"; shift 2 ;;
    --config-dir)
      WG_CONFIG_DIR="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

SERVER_ENV="${WG_CONFIG_DIR}/${WG_INTERFACE}.env"
if [[ -f "${SERVER_ENV}" ]]; then
  # shellcheck disable=SC1090
  source "${SERVER_ENV}"
fi

WG_STATE_FILE="${WG_STATE_FILE:-${WG_CONFIG_DIR}/${WG_INTERFACE}.clients}"
WG_CLIENTS_DIR="${WG_CLIENTS_DIR:-${WG_CONFIG_DIR}/clients}"

if [[ ! -s "${WG_STATE_FILE}" ]]; then
  echo "No clients found."
  echo "Clients directory: ${WG_CLIENTS_DIR}"
  exit 0
fi

printf '%-24s %-15s %-44s %s\n' "NAME" "VPN_IP" "PUBLIC_KEY" "CREATED_UTC"
awk -F '\t' '{printf "%-24s %-15s %-44s %s\n", $1, $2, $3, $4}' "${WG_STATE_FILE}"

if command -v wg >/dev/null 2>&1 && wg show "${WG_INTERFACE}" >/dev/null 2>&1; then
  echo
  echo "Live WireGuard status:"
  wg show "${WG_INTERFACE}" latest-handshakes transfer
fi
