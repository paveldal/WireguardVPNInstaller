#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/wg-lib.sh"

ENTRY_ENDPOINT=""
EXIT_HOST=""
EXIT_ENDPOINT=""
ENTRY_PORT=51820
EXIT_PORT=51821
CLIENT_PREFIX="10.8.0"
CHAIN_PREFIX="10.77.0"
CLIENT_NAME="phone"
DNS="1.1.1.1, 1.0.0.1"
ENTRY_INTERFACE="wg0"
CHAIN_INTERFACE="wg-chain"
ROUTE_TABLE=51821
ROUTE_PRIORITY=100
SSH_KEY=""
SSH_PORT=""
FORCE=0
SKIP_CLIENT=0
ALLOW_DIRECT_FALLBACK=0

usage() {
  cat <<USAGE
Usage: sudo $0 --entry-endpoint IP_OR_DNS --exit-host SSH_HOST --exit-endpoint IP_OR_DNS [options]

Options:
  --entry-endpoint HOST      Public address clients connect to.
  --exit-host SSH_HOST       SSH target for the exit server, for example root@EXIT_PUBLIC_IP.
  --exit-endpoint HOST       Public address of the exit server.
  --entry-port PORT          Client-facing UDP port. Default: ${ENTRY_PORT}
  --exit-port PORT           Entry-to-exit UDP port. Default: ${EXIT_PORT}
  --client-prefix A.B.C      Client /24 prefix. Default: ${CLIENT_PREFIX}
  --chain-prefix A.B.C       Entry-exit /30 prefix. Default: ${CHAIN_PREFIX}
  --client-name NAME         Client config name to create. Default: ${CLIENT_NAME}
  --dns LIST                 DNS value for client config. Default: ${DNS}
  --ssh-key PATH             SSH private key for exit server.
  --ssh-port PORT            SSH port for exit server.
  --allow-direct-fallback    Do not reject client egress outside the chain.
  --skip-client              Configure servers only.
  --force                    Backup and replace managed WireGuard files.
  -h, --help                 Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry-endpoint)
      ENTRY_ENDPOINT="${2:-}"; shift 2 ;;
    --exit-host)
      EXIT_HOST="${2:-}"; shift 2 ;;
    --exit-endpoint)
      EXIT_ENDPOINT="${2:-}"; shift 2 ;;
    --entry-port)
      ENTRY_PORT="${2:-}"; shift 2 ;;
    --exit-port)
      EXIT_PORT="${2:-}"; shift 2 ;;
    --client-prefix)
      CLIENT_PREFIX="${2:-}"; shift 2 ;;
    --chain-prefix)
      CHAIN_PREFIX="${2:-}"; shift 2 ;;
    --client-name)
      CLIENT_NAME="${2:-}"; shift 2 ;;
    --dns)
      DNS="${2:-}"; shift 2 ;;
    --ssh-key)
      SSH_KEY="${2:-}"; shift 2 ;;
    --ssh-port)
      SSH_PORT="${2:-}"; shift 2 ;;
    --allow-direct-fallback)
      ALLOW_DIRECT_FALLBACK=1; shift ;;
    --skip-client)
      SKIP_CLIENT=1; shift ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      wg_fail "unknown option: $1" ;;
  esac
done

[[ -n "${ENTRY_ENDPOINT}" ]] || wg_fail "--entry-endpoint is required"
[[ -n "${EXIT_HOST}" ]] || wg_fail "--exit-host is required"
[[ -n "${EXIT_ENDPOINT}" ]] || wg_fail "--exit-endpoint is required"
wg_valid_port "${ENTRY_PORT}" || wg_fail "invalid --entry-port"
wg_valid_port "${EXIT_PORT}" || wg_fail "invalid --exit-port"
wg_valid_prefix "${CLIENT_PREFIX}" || wg_fail "invalid --client-prefix"
wg_valid_prefix "${CHAIN_PREFIX}" || wg_fail "invalid --chain-prefix"
wg_valid_name "${ENTRY_INTERFACE}" || wg_fail "invalid entry interface"
wg_valid_name "${CHAIN_INTERFACE}" || wg_fail "invalid chain interface"
wg_valid_client_name "${CLIENT_NAME}" || wg_fail "invalid --client-name"
if [[ -n "${SSH_PORT}" ]]; then
  wg_valid_port "${SSH_PORT}" || wg_fail "invalid --ssh-port"
fi

wg_require_root
umask 077

CLIENT_CIDR="${CLIENT_PREFIX}.0/24"
CHAIN_CIDR="${CHAIN_PREFIX}.0/30"
ENTRY_CLIENT_IP="${CLIENT_PREFIX}.1"
ENTRY_CHAIN_IP="${CHAIN_PREFIX}.2"
EXIT_CHAIN_IP="${CHAIN_PREFIX}.1"
WG_CONFIG_DIR="/etc/wireguard"
KEYS_DIR="${WG_CONFIG_DIR}/keys"
CLIENTS_DIR="${WG_CONFIG_DIR}/clients"
STATE_DIR="${WG_CONFIG_DIR}/wg-installer"
ENTRY_CONF="${WG_CONFIG_DIR}/${ENTRY_INTERFACE}.conf"
CHAIN_CONF="${WG_CONFIG_DIR}/${CHAIN_INTERFACE}.conf"
SERVER_PRIVATE_KEY_FILE="${KEYS_DIR}/server_private.key"
SERVER_PUBLIC_KEY_FILE="${KEYS_DIR}/server_public.key"
ENTRY_PRIVATE_KEY_FILE="${KEYS_DIR}/chain_entry_private.key"
ENTRY_PUBLIC_KEY_FILE="${KEYS_DIR}/chain_entry_public.key"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-o StrictHostKeyChecking=accept-new)
if [[ -n "${SSH_KEY}" ]]; then
  SSH_OPTS+=(-i "${SSH_KEY}")
  SCP_OPTS+=(-i "${SSH_KEY}")
fi
if [[ -n "${SSH_PORT}" ]]; then
  SSH_OPTS+=(-p "${SSH_PORT}")
  SCP_OPTS+=(-P "${SSH_PORT}")
fi

make_remote_payload() {
  local path="$1"
  cat > "${path}" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/local/sbin:/usr/sbin:/sbin"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iptables curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wireguard-tools iptables curl
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --needed --noconfirm wireguard-tools iptables curl
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install wireguard-tools iptables curl
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache wireguard-tools wireguard-tools-wg-quick iptables curl
  else
    fail "unsupported package manager on exit host"
  fi
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command on exit host: $1"
}

detect_public_ip() {
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsS --max-time 8 https://api.ipify.org && return
  fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

detect_wan_iface() {
  ip -4 route list default 0.0.0.0/0 2>/dev/null | awk '{print $5; exit}'
}

stop_service() {
  local interface="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "wg-quick@${interface}" 2>/dev/null || true
    systemctl reset-failed "wg-quick@${interface}" 2>/dev/null || true
  else
    wg-quick down "${interface}" 2>/dev/null || true
  fi
  ip link delete "${interface}" 2>/dev/null || true
}

backup_file() {
  local path="$1"
  local backup
  if [[ -f "${path}" ]]; then
    backup="${path}.bak.$(date -u +%Y%m%d%H%M%S)"
    cp -p "${path}" "${backup}"
    echo "Backup: ${backup}"
  fi
}

ensure_key_pair() {
  local private_file="$1"
  local public_file="$2"
  if [[ ! -f "${private_file}" ]]; then
    wg genkey > "${private_file}"
  fi
  wg pubkey < "${private_file}" > "${public_file}"
  chmod 600 "${private_file}" "${public_file}"
}

allow_udp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "${port}/udp" || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="${port}/udp" --permanent || true
    firewall-cmd --reload || true
  fi
}

delete_rule_loop() {
  local table="$1"
  shift
  if [[ -n "${table}" ]]; then
    while iptables -t "${table}" -C "$@" 2>/dev/null; do
      iptables -t "${table}" -D "$@" 2>/dev/null || break
    done
  else
    while iptables -C "$@" 2>/dev/null; do
      iptables -D "$@" 2>/dev/null || break
    done
  fi
}

enable_service() {
  local interface="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now "wg-quick@${interface}"
  else
    wg-quick up "${interface}"
  fi
}

[[ "${EUID}" -eq 0 ]] || fail "exit host command must run as root"

: "${ENTRY_PUBLIC_KEY:?}"
: "${EXIT_ENDPOINT:?}"
: "${EXIT_PORT:?}"
: "${CLIENT_PREFIX:?}"
: "${CHAIN_PREFIX:?}"
: "${CHAIN_INTERFACE:?}"
: "${FORCE:?}"

CLIENT_CIDR="${CLIENT_PREFIX}.0/24"
CHAIN_CIDR="${CHAIN_PREFIX}.0/30"
ENTRY_CHAIN_IP="${CHAIN_PREFIX}.2"
EXIT_CHAIN_IP="${CHAIN_PREFIX}.1"
WG_CONFIG_DIR="/etc/wireguard"
KEYS_DIR="${WG_CONFIG_DIR}/keys"
STATE_DIR="${WG_CONFIG_DIR}/wg-installer"
CHAIN_CONF="${WG_CONFIG_DIR}/${CHAIN_INTERFACE}.conf"
EXIT_PRIVATE_KEY_FILE="${KEYS_DIR}/chain_exit_private.key"
EXIT_PUBLIC_KEY_FILE="${KEYS_DIR}/chain_exit_public.key"

install_packages
need_command wg
need_command wg-quick
need_command ip
need_command iptables
need_command awk

CURRENT_PUBLIC_IP="$(detect_public_ip || true)"
if valid_ipv4 "${EXIT_ENDPOINT}" && [[ -n "${CURRENT_PUBLIC_IP}" && "${CURRENT_PUBLIC_IP}" != "${EXIT_ENDPOINT}" ]]; then
  fail "exit host public IP is ${CURRENT_PUBLIC_IP}, expected ${EXIT_ENDPOINT}"
fi

WAN_IF="$(detect_wan_iface)"
[[ -n "${WAN_IF}" ]] || fail "could not detect exit host WAN interface"

if [[ "${FORCE}" == "1" ]]; then
  stop_service "${CHAIN_INTERFACE}"
  stop_service "wg-exit"
  stop_service "wg0"
fi

mkdir -p "${KEYS_DIR}" "${STATE_DIR}"
chmod 700 "${WG_CONFIG_DIR}" "${KEYS_DIR}" "${STATE_DIR}"

if [[ -f "${CHAIN_CONF}" && "${FORCE}" != "1" ]]; then
  fail "${CHAIN_CONF} exists on exit host; pass --force"
fi

backup_file "${CHAIN_CONF}"
backup_file "${WG_CONFIG_DIR}/wg-exit.conf"
backup_file "${WG_CONFIG_DIR}/wg0.conf"

ensure_key_pair "${EXIT_PRIVATE_KEY_FILE}" "${EXIT_PUBLIC_KEY_FILE}"
EXIT_PRIVATE_KEY="$(<"${EXIT_PRIVATE_KEY_FILE}")"
EXIT_PUBLIC_KEY="$(<"${EXIT_PUBLIC_KEY_FILE}")"

delete_rule_loop nat POSTROUTING -s "${CLIENT_CIDR}" -o "${WAN_IF}" -j MASQUERADE
delete_rule_loop '' FORWARD -i "${CHAIN_INTERFACE}" -o "${WAN_IF}" -s "${CLIENT_CIDR}" -j ACCEPT
delete_rule_loop '' FORWARD -i "${WAN_IF}" -o "${CHAIN_INTERFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

cat > "${CHAIN_CONF}" <<CONF
[Interface]
Address = ${EXIT_CHAIN_IP}/30
ListenPort = ${EXIT_PORT}
PrivateKey = ${EXIT_PRIVATE_KEY}
Table = off
SaveConfig = false
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; ip route replace ${CLIENT_CIDR} dev ${CHAIN_INTERFACE}; iptables -t nat -C POSTROUTING -s ${CLIENT_CIDR} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${CLIENT_CIDR} -o ${WAN_IF} -j MASQUERADE; iptables -C FORWARD -i ${CHAIN_INTERFACE} -o ${WAN_IF} -s ${CLIENT_CIDR} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${CHAIN_INTERFACE} -o ${WAN_IF} -s ${CLIENT_CIDR} -j ACCEPT; iptables -C FORWARD -i ${WAN_IF} -o ${CHAIN_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${WAN_IF} -o ${CHAIN_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = ip route del ${CLIENT_CIDR} dev ${CHAIN_INTERFACE} 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${CLIENT_CIDR} -o ${WAN_IF} -j MASQUERADE 2>/dev/null || true; iptables -D FORWARD -i ${CHAIN_INTERFACE} -o ${WAN_IF} -s ${CLIENT_CIDR} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${WAN_IF} -o ${CHAIN_INTERFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

[Peer]
PublicKey = ${ENTRY_PUBLIC_KEY}
AllowedIPs = ${ENTRY_CHAIN_IP}/32, ${CLIENT_CIDR}
CONF

chmod 600 "${CHAIN_CONF}"
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-chain.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
allow_udp "${EXIT_PORT}"
enable_service "${CHAIN_INTERFACE}"

cat > "${STATE_DIR}/exit.env" <<STATE
ROLE=exit
CHAIN_INTERFACE=${CHAIN_INTERFACE}
CLIENT_CIDR=${CLIENT_CIDR}
CHAIN_CIDR=${CHAIN_CIDR}
EXIT_ENDPOINT=${EXIT_ENDPOINT}
EXIT_PORT=${EXIT_PORT}
WAN_IF=${WAN_IF}
STATE
chmod 600 "${STATE_DIR}/exit.env"

echo "Exit host configured."
echo "Exit public IP: ${CURRENT_PUBLIC_IP:-unknown}"
echo "Exit WAN interface: ${WAN_IF}"
echo "Exit WireGuard config: ${CHAIN_CONF}"
echo "__WG_EXIT_PUBLIC_KEY=${EXIT_PUBLIC_KEY}"
REMOTE
  chmod 700 "${path}"
}

remote_run() {
  local payload="$1"
  local remote_path="/tmp/wg-chain-setup-$RANDOM-$$.sh"
  local remote_cmd
  scp "${SCP_OPTS[@]}" "${payload}" "${EXIT_HOST}:${remote_path}" >/dev/null
  remote_cmd="$(printf 'ENTRY_PUBLIC_KEY=%q EXIT_ENDPOINT=%q EXIT_PORT=%q CLIENT_PREFIX=%q CHAIN_PREFIX=%q CHAIN_INTERFACE=%q FORCE=%q bash %q; status=$?; rm -f %q; exit $status' \
    "${ENTRY_PUBLIC_KEY}" "${EXIT_ENDPOINT}" "${EXIT_PORT}" "${CLIENT_PREFIX}" "${CHAIN_PREFIX}" "${CHAIN_INTERFACE}" "${FORCE}" "${remote_path}" "${remote_path}")"
  ssh "${SSH_OPTS[@]}" "${EXIT_HOST}" "${remote_cmd}"
}

write_entry_env() {
  {
    wg_shell_env WG_INTERFACE "${ENTRY_INTERFACE}"
    wg_shell_env WG_PORT "${ENTRY_PORT}"
    wg_shell_env WG_IPV4_PREFIX "${CLIENT_PREFIX}"
    wg_shell_env WG_SERVER_IPV4 "${ENTRY_CLIENT_IP}"
    wg_shell_env WG_NETWORK_CIDR "${CLIENT_CIDR}"
    wg_shell_env WG_DNS "${DNS}"
    wg_shell_env WG_CLIENT_ALLOWED_IPS "0.0.0.0/0"
    wg_shell_env WG_KEEPALIVE "25"
    wg_shell_env WG_ENDPOINT "${ENTRY_ENDPOINT}"
    wg_shell_env WG_CONFIG_DIR "${WG_CONFIG_DIR}"
    wg_shell_env WG_CLIENTS_DIR "${CLIENTS_DIR}"
    wg_shell_env WG_STATE_FILE "${WG_CONFIG_DIR}/${ENTRY_INTERFACE}.clients"
  } > "${WG_CONFIG_DIR}/${ENTRY_INTERFACE}.env"
  chmod 600 "${WG_CONFIG_DIR}/${ENTRY_INTERFACE}.env"
}

next_client_name_available() {
  [[ ! -e "${CLIENTS_DIR}/${CLIENT_NAME}" ]]
}

cleanup_entry_rules() {
  local wan_if="$1"
  wg_delete_rule_loop nat POSTROUTING -s "${CLIENT_CIDR}" -o "${wan_if}" -j MASQUERADE
  wg_delete_rule_loop '' FORWARD -i "${ENTRY_INTERFACE}" -o "${wan_if}" -j ACCEPT
  wg_delete_rule_loop '' FORWARD -i "${wan_if}" -o "${ENTRY_INTERFACE}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  wg_delete_rule_loop '' FORWARD -i "${ENTRY_INTERFACE}" -o "${CHAIN_INTERFACE}" -s "${CLIENT_CIDR}" -j ACCEPT
  wg_delete_rule_loop '' FORWARD -i "${CHAIN_INTERFACE}" -o "${ENTRY_INTERFACE}" -d "${CLIENT_CIDR}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  wg_delete_rule_loop '' FORWARD -i "${ENTRY_INTERFACE}" -s "${CLIENT_CIDR}" ! -d "${CLIENT_CIDR}" ! -o "${CHAIN_INTERFACE}" -j REJECT
}

write_entry_configs() {
  local server_private
  local entry_private
  local kill_rule_post_up=""
  local kill_rule_post_down=""
  server_private="$(<"${SERVER_PRIVATE_KEY_FILE}")"
  entry_private="$(<"${ENTRY_PRIVATE_KEY_FILE}")"

  if [[ "${ALLOW_DIRECT_FALLBACK}" != "1" ]]; then
    kill_rule_post_up="; iptables -C FORWARD -i ${ENTRY_INTERFACE} -s ${CLIENT_CIDR} ! -d ${CLIENT_CIDR} ! -o ${CHAIN_INTERFACE} -j REJECT 2>/dev/null || iptables -I FORWARD 1 -i ${ENTRY_INTERFACE} -s ${CLIENT_CIDR} ! -d ${CLIENT_CIDR} ! -o ${CHAIN_INTERFACE} -j REJECT"
    kill_rule_post_down="; iptables -D FORWARD -i ${ENTRY_INTERFACE} -s ${CLIENT_CIDR} ! -d ${CLIENT_CIDR} ! -o ${CHAIN_INTERFACE} -j REJECT 2>/dev/null || true"
  fi

  cat > "${ENTRY_CONF}" <<CONF
[Interface]
Address = ${ENTRY_CLIENT_IP}/24
ListenPort = ${ENTRY_PORT}
PrivateKey = ${server_private}
SaveConfig = false
CONF

  cat > "${CHAIN_CONF}" <<CONF
[Interface]
Address = ${ENTRY_CHAIN_IP}/30
PrivateKey = ${entry_private}
Table = off
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; ip rule del from ${CLIENT_CIDR} table ${ROUTE_TABLE} priority ${ROUTE_PRIORITY} 2>/dev/null || true; ip rule add from ${CLIENT_CIDR} table ${ROUTE_TABLE} priority ${ROUTE_PRIORITY}; ip route replace ${CLIENT_CIDR} dev ${ENTRY_INTERFACE} table ${ROUTE_TABLE}; ip route replace default dev ${CHAIN_INTERFACE} table ${ROUTE_TABLE}; iptables -C FORWARD -i ${ENTRY_INTERFACE} -o ${CHAIN_INTERFACE} -s ${CLIENT_CIDR} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${ENTRY_INTERFACE} -o ${CHAIN_INTERFACE} -s ${CLIENT_CIDR} -j ACCEPT; iptables -C FORWARD -i ${CHAIN_INTERFACE} -o ${ENTRY_INTERFACE} -d ${CLIENT_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${CHAIN_INTERFACE} -o ${ENTRY_INTERFACE} -d ${CLIENT_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT${kill_rule_post_up}
PostDown = ip rule del from ${CLIENT_CIDR} table ${ROUTE_TABLE} priority ${ROUTE_PRIORITY} 2>/dev/null || true; ip route flush table ${ROUTE_TABLE} 2>/dev/null || true${kill_rule_post_down}; iptables -D FORWARD -i ${ENTRY_INTERFACE} -o ${CHAIN_INTERFACE} -s ${CLIENT_CIDR} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${CHAIN_INTERFACE} -o ${ENTRY_INTERFACE} -d ${CLIENT_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

[Peer]
PublicKey = ${EXIT_PUBLIC_KEY}
Endpoint = ${EXIT_ENDPOINT}:${EXIT_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF

  chmod 600 "${ENTRY_CONF}" "${CHAIN_CONF}"
}

write_state() {
  cat > "${STATE_DIR}/entry.env" <<STATE
ROLE=entry
ENTRY_ENDPOINT=${ENTRY_ENDPOINT}
EXIT_ENDPOINT=${EXIT_ENDPOINT}
EXIT_HOST=${EXIT_HOST}
ENTRY_PORT=${ENTRY_PORT}
EXIT_PORT=${EXIT_PORT}
ENTRY_INTERFACE=${ENTRY_INTERFACE}
CHAIN_INTERFACE=${CHAIN_INTERFACE}
CLIENT_CIDR=${CLIENT_CIDR}
CHAIN_CIDR=${CHAIN_CIDR}
ROUTE_TABLE=${ROUTE_TABLE}
ROUTE_PRIORITY=${ROUTE_PRIORITY}
STATE
  chmod 600 "${STATE_DIR}/entry.env"
}

create_client() {
  if [[ "${SKIP_CLIENT}" == "1" ]]; then
    return
  fi
  if ! next_client_name_available; then
    if [[ "${FORCE}" == "1" ]]; then
      wg_backup_dir "${CLIENTS_DIR}/${CLIENT_NAME}"
    else
      wg_fail "client ${CLIENT_NAME} already exists; pass --force or use --client-name"
    fi
  fi
  "${SCRIPT_DIR}/add-client.sh" "${CLIENT_NAME}" --endpoint "${ENTRY_ENDPOINT}" --dns "${DNS}"
}

wg_install_packages
wg_need_command wg
wg_need_command wg-quick
wg_need_command ip
wg_need_command iptables
wg_need_command awk
wg_need_command ssh
wg_need_command scp
wg_need_command mktemp
wg_assert_public_ip "${ENTRY_ENDPOINT}"

WAN_IF="$(wg_detect_wan_iface)"
[[ -n "${WAN_IF}" ]] || wg_fail "could not detect entry WAN interface"

mkdir -p "${KEYS_DIR}" "${CLIENTS_DIR}" "${STATE_DIR}"
chmod 700 "${WG_CONFIG_DIR}" "${KEYS_DIR}" "${CLIENTS_DIR}" "${STATE_DIR}"

if [[ "${FORCE}" == "1" ]]; then
  wg_stop_service "${CHAIN_INTERFACE}"
  wg_stop_service "wg-exit"
  wg_stop_service "${ENTRY_INTERFACE}"
  cleanup_entry_rules "${WAN_IF}"
fi

if [[ -f "${ENTRY_CONF}" && "${FORCE}" != "1" ]]; then
  wg_fail "${ENTRY_CONF} exists; pass --force"
fi
if [[ -f "${CHAIN_CONF}" && "${FORCE}" != "1" ]]; then
  wg_fail "${CHAIN_CONF} exists; pass --force"
fi

wg_backup_file "${ENTRY_CONF}"
wg_backup_file "${CHAIN_CONF}"
wg_backup_file "${WG_CONFIG_DIR}/wg-exit.conf"
if [[ "${FORCE}" == "1" ]]; then
  wg_backup_file "${WG_CONFIG_DIR}/${ENTRY_INTERFACE}.clients"
  rm -f "${WG_CONFIG_DIR}/${ENTRY_INTERFACE}.clients"
  rm -rf "${WG_CONFIG_DIR}/.${ENTRY_INTERFACE}.lock"
fi

wg_ensure_key_pair "${SERVER_PRIVATE_KEY_FILE}" "${SERVER_PUBLIC_KEY_FILE}"
wg_ensure_key_pair "${ENTRY_PRIVATE_KEY_FILE}" "${ENTRY_PUBLIC_KEY_FILE}"
ENTRY_PUBLIC_KEY="$(<"${ENTRY_PUBLIC_KEY_FILE}")"

REMOTE_PAYLOAD="$(mktemp)"
REMOTE_LOG="$(mktemp)"
trap 'rm -f "${REMOTE_PAYLOAD}" "${REMOTE_LOG}"' EXIT
make_remote_payload "${REMOTE_PAYLOAD}"

echo "Configuring exit host ${EXIT_HOST}..."
if ! remote_run "${REMOTE_PAYLOAD}" | tee "${REMOTE_LOG}"; then
  wg_fail "exit host setup failed"
fi

EXIT_PUBLIC_KEY="$(sed -n 's/^__WG_EXIT_PUBLIC_KEY=//p' "${REMOTE_LOG}" | tail -n 1)"
[[ -n "${EXIT_PUBLIC_KEY}" ]] || wg_fail "exit public key was not returned"

write_entry_env
write_entry_configs
write_state

echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard-chain.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
wg_allow_udp "${ENTRY_PORT}"
wg_enable_service "${ENTRY_INTERFACE}"
wg_enable_service "${CHAIN_INTERFACE}"

create_client

echo "Chain configured."
echo "Entry endpoint: ${ENTRY_ENDPOINT}:${ENTRY_PORT}"
echo "Exit endpoint: ${EXIT_ENDPOINT}:${EXIT_PORT}"
echo "Client network: ${CLIENT_CIDR}"
echo "Chain network: ${CHAIN_CIDR}"
if [[ "${SKIP_CLIENT}" != "1" ]]; then
  echo "Client config: ${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.conf"
  if command -v qrencode >/dev/null 2>&1; then
    echo "QR: qrencode -t ansiutf8 < ${CLIENTS_DIR}/${CLIENT_NAME}/${CLIENT_NAME}.conf"
  fi
fi
echo "Expected client public IP: ${EXIT_ENDPOINT}"
