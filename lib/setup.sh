#!/bin/bash

# ================================
# setup.sh — ИСПРАВЛЕННАЯ ПОЛНАЯ ВЕРСИЯ
# ================================

set -euo pipefail

# ---------- БАЗОВЫЕ ПЕРЕМЕННЫЕ ----------
WG_DIR="/etc/wireguard"
WG_INTERFACE="wg0"
WG_CONFIG_FILE="$WG_DIR/${WG_INTERFACE}.conf"
WG_PRIVATE_KEY_FILE="$WG_DIR/private.key"
WG_PUBLIC_KEY_FILE="$WG_DIR/public.key"

# Значения по умолчанию (если не заданы из menu/config)
WG_MODE="${WG_MODE:-full}"
WG_PORT="${WG_PORT:-29717}"
WG_SERVER_IP="${WG_SERVER_IP:-10.99.0.1}"
HOME_DNS_WG_IP="${HOME_DNS_WG_IP:-10.99.0.100}"
HOME_NET="${HOME_NET:-192.168.0.0/24}"

# ---------- УТИЛИТЫ ----------
log_message() {
    echo "[$1] $2"
}

validate_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

get_public_interface() {
    ip route | awk '/default/ {print $5; exit}'
}

enable_ip_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

open_firewall_port() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$port/udp" || true
    fi
}

# ---------- УСТАНОВКА WG ----------
install_wireguard() {
    log_message INFO "Установка WireGuard"
    apt-get update
    apt-get install -y wireguard
}

# ---------- КЛЮЧИ ----------
generate_server_keys() {
    log_message INFO "Генерация ключей сервера"
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"

    umask 077
    wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey > "$WG_PUBLIC_KEY_FILE"
    umask 022

    chmod 600 "$WG_PRIVATE_KEY_FILE" "$WG_PUBLIC_KEY_FILE"
}

# ---------- КОНФИГ ----------
generate_wg_config() {
    local iface="$1"
    local privkey
    privkey=$(cat "$WG_PRIVATE_KEY_FILE")

    log_message INFO "Генерация $WG_CONFIG_FILE"

    cat > "$WG_CONFIG_FILE" <<EOF
[Interface]
Address = $WG_SERVER_IP/24
ListenPort = $WG_PORT
PrivateKey = $privkey

PostUp = iptables -A FORWARD -i %i -o $iface -j ACCEPT; \
         iptables -A FORWARD -i $iface -o %i -j ACCEPT; \
         iptables -t nat -A POSTROUTING -s $WG_SERVER_IP/24 -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o $iface -j ACCEPT; \
           iptables -D FORWARD -i $iface -o %i -j ACCEPT; \
           iptables -t nat -D POSTROUTING -s $WG_SERVER_IP/24 -o $iface -j MASQUERADE

# HOME GATEWAY (добавить позже)
# [Peer]
# PublicKey = <HOME_GATEWAY_PUBLIC_KEY>
# AllowedIPs = $HOME_DNS_WG_IP/32, $HOME_NET
EOF

    chmod 600 "$WG_CONFIG_FILE"
}

# ---------- ТОЧКА ВХОДА ----------
initial_setup_main() {
    log_message INFO "Запуск первоначальной настройки"

    install_wireguard

    local iface
    iface=$(get_public_interface)
    if [[ -z "$iface" ]]; then
        log_message ERROR "Не удалось определить сетевой интерфейс"
        exit 1
    fi

    generate_server_keys
    generate_wg_config "$iface"

    enable_ip_forwarding
    open_firewall_port "$WG_PORT"

    systemctl enable "wg-quick@${WG_INTERFACE}"
    systemctl restart "wg-quick@${WG_INTERFACE}"

    log_message INFO "WireGuard успешно настроен"
}


# ---------- АВТОЗАПУСК ПРИ ПРЯМОМ ВЫЗОВЕ ----------
# Если файл запущен напрямую, а не через source — выполняем initial_setup_main
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    initial_setup_main
fi

