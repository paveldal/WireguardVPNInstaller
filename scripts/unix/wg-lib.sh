#!/usr/bin/env bash

export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}:/usr/local/sbin:/usr/sbin:/sbin"

wg_fail() {
  echo "ERROR: $*" >&2
  exit 1
}

wg_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    wg_fail "run as root"
  fi
}

wg_need_command() {
  command -v "$1" >/dev/null 2>&1 || wg_fail "missing command: $1"
}

wg_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]
}

wg_valid_client_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]
}

wg_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

wg_valid_prefix() {
  [[ "$1" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]]
}

wg_valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

wg_valid_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

wg_install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables qrencode curl openssh-client
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iptables qrencode curl openssh-clients
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wireguard-tools iptables qrencode curl openssh-clients
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --needed --noconfirm wireguard-tools iptables qrencode curl openssh
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install wireguard-tools iptables qrencode curl openssh-clients
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache wireguard-tools wireguard-tools-wg-quick iptables qrencode curl openssh-client
  else
    wg_fail "unsupported package manager"
  fi
}

wg_detect_public_ip() {
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsS --max-time 8 https://api.ipify.org && return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -4 -qO- --timeout=8 https://api.ipify.org && return
  fi
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
}

wg_detect_wan_iface() {
  ip -4 route list default 0.0.0.0/0 2>/dev/null | awk '{print $5; exit}'
}

wg_backup_file() {
  local path="$1"
  local backup
  if [[ -f "${path}" ]]; then
    backup="${path}.bak.$(date -u +%Y%m%d%H%M%S)"
    cp -p "${path}" "${backup}"
    echo "Backup: ${backup}"
  fi
}

wg_backup_dir() {
  local path="$1"
  local backup
  if [[ -d "${path}" ]]; then
    backup="${path}.bak.$(date -u +%Y%m%d%H%M%S)"
    mv "${path}" "${backup}"
    echo "Backup: ${backup}"
  fi
}

wg_ensure_key_pair() {
  local private_file="$1"
  local public_file="$2"
  mkdir -p "$(dirname "${private_file}")"
  if [[ ! -f "${private_file}" ]]; then
    wg genkey > "${private_file}"
  fi
  wg pubkey < "${private_file}" > "${public_file}"
  chmod 600 "${private_file}" "${public_file}"
}

wg_stop_service() {
  local interface="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "wg-quick@${interface}" 2>/dev/null || true
    systemctl reset-failed "wg-quick@${interface}" 2>/dev/null || true
  else
    wg-quick down "${interface}" 2>/dev/null || true
  fi
  ip link delete "${interface}" 2>/dev/null || true
}

wg_enable_service() {
  local interface="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now "wg-quick@${interface}"
  else
    wg-quick up "${interface}"
  fi
}

wg_allow_udp() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw allow "${port}/udp" || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="${port}/udp" --permanent || true
    firewall-cmd --reload || true
  fi
}

wg_shell_env() {
  local name="$1"
  local value="$2"
  printf '%s=%q\n' "${name}" "${value}"
}

wg_assert_public_ip() {
  local expected="$1"
  local actual
  if wg_valid_ipv4 "${expected}"; then
    actual="$(wg_detect_public_ip || true)"
    [[ -n "${actual}" ]] || wg_fail "could not detect public IP"
    [[ "${actual}" == "${expected}" ]] || wg_fail "this host public IP is ${actual}, expected ${expected}"
  fi
}

wg_delete_rule_loop() {
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
