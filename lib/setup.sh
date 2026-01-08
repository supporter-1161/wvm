#!/bin/bash

# ================================
# setup.sh — ИСПРАВЛЕННАЯ ПОЛНАЯ ВЕРСИЯ (обновленная)
# ================================

set -euo pipefail

# ---------- БАЗОВЫЕ ПЕРЕМЕННЫЕ ----------
WG_DIR="/etc/wireguard"
WG_INTERFACE="wg0"
WG_CONFIG_FILE="$WG_DIR/${WG_INTERFACE}.conf"
WG_PRIVATE_KEY_FILE="$WG_DIR/private.key"
WG_PUBLIC_KEY_FILE="$WG_DIR/public.key"

# Значения по умолчанию (если не заданы из menu/config)
WG_MODE="${WG_MODE:-full}" # Передается из wg-setup.sh
WG_PORT="${WG_PORT:-29717}" # Передается из wg-setup.sh
WG_NET="${WG_NET:-10.99.0.0/24}" # Передается из wg-setup.sh
WG_SERVER_IP="${WG_SERVER_IP:-10.99.0.1}" # Должно быть вычислено из WG_NET
HOME_DNS_WG_IP="${HOME_DNS_WG_IP:-10.99.0.100}" # Передается из wg-setup.sh
HOME_NET="${HOME_NET:-192.168.0.0/24}" # Передается из wg-setup.sh
SERVER_PUBLIC_IP="${SERVER_PUBLIC_IP:-}" # Должно быть передано из wg-setup.sh
PUBLIC_INTERFACE="${PUBLIC_INTERFACE:-}" # Должно быть передано из wg-setup.sh

# Пути по умолчанию
CLIENTS_DIR_DEFAULT="/etc/wireguard/clients"
BACKUP_DIR_DEFAULT="/etc/wireguard/backup"
LOG_FILE_DEFAULT="/etc/wireguard/logs/setup.log"

# ---------- УТИЛИТЫ ----------
# log_message должна быть определена в functions.sh и подключена в wg-setup.sh
# validate_ip должна быть определена в functions.sh
# get_public_interface должна быть определена в functions.sh (без логирования!)

enable_ip_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

open_firewall_port() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$port/udp" || true
    fi
}

# --- Функция обновления файла конфигурации скрипта (config.env) ---
# Теперь принимает все необходимые параметры
update_config_file() {
    local mode="$1"
    local port="$2"
    local net="$3"
    local server_ip="$4"
    local home_dns_ip="$5"
    local home_net="$6"
    local public_ip="$7"
    local pub_iface="$8"
    local clients_dir="$9"
    local backup_dir="${10}"
    local log_file="${11}"

    local new_config_file="${CONFIG_FILE:-/etc/wireguard/config.env}" # CONFIG_FILE должен быть передан из wg-setup.sh

    log_message "INFO" "Обновление файла конфигурации скрипта: $new_config_file"

    # Создаем директорию для config.env, если не существует
    local config_dir=$(dirname "$new_config_file")
    mkdir -p "$config_dir"

    # Записываем обновленные значения в новый файл
    cat > "$new_config_file" << EOF
# --- Обновленная конфигурация скрипта wg-setup.sh после установки ---

# Основные настройки
WG_MODE="$mode"
WG_PORT="$port"
WG_NET="$net"
WG_SERVER_IP="$server_ip"

# Домашняя сеть
HOME_NET="$home_net"
HOME_DNS_WG_IP="$home_dns_ip"

# Сеть клиентов
CLIENT_NET_START="${WG_SERVER_IP%.*}.2"  # x.x.x.2
CLIENT_NET_END="${WG_SERVER_IP%.*}.254" # x.x.x.254

# VPS настройки
SERVER_PUBLIC_IP="$public_ip"
PUBLIC_INTERFACE="$pub_iface"

# Пути (на целевой системе VPS)
WG_CONFIG_FILE="${WG_CONFIG_FILE}"
WG_PRIVATE_KEY_FILE="${WG_PRIVATE_KEY_FILE}"
WG_PUBLIC_KEY_FILE="${WG_PUBLIC_KEY_FILE}"
CLIENTS_DIR="$clients_dir"
BACKUP_DIR="$backup_dir"
LOG_FILE="$log_file"

# Статус установки
SETUP_COMPLETED="true"
EOF

    chmod 600 "$new_config_file"
    log_message "INFO" "Файл конфигурации $new_config_file обновлен и права установлены (0600)."
}


# ---------- УСТАНОВКА WG ----------
install_wireguard() {
    log_message "INFO" "Установка WireGuard"
    apt-get update
    apt-get install -y wireguard
}

# ---------- КЛЮЧИ ----------
generate_server_keys() {
    log_message "INFO" "Генерация ключей сервера"
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

    log_message "INFO" "Генерация $WG_CONFIG_FILE"

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
    # --- Запрашиваем недостающие параметры ---
    # wg-setup.sh теперь должен передавать SERVER_PUBLIC_IP и PUBLIC_INTERFACE
    # Проверим, что они заданы
    if [[ -z "${SERVER_PUBLIC_IP:-}" ]] || [[ -z "${PUBLIC_INTERFACE:-}" ]]; then
        log_message "ERROR" "Переменные SERVER_PUBLIC_IP и PUBLIC_INTERFACE не заданы. initial_setup_main не может выполниться."
        exit 1
    fi

    # Если WG_NET передан, вычисляем WG_SERVER_IP
    if [[ -n "${WG_NET:-}" ]]; then
        WG_SERVER_IP=$(echo "$WG_NET" | sed 's/\/24//')
        WG_SERVER_IP="${WG_SERVER_IP%.*}.1"
        log_message "INFO" "IP сервера в VPN определен из WG_NET как: $WG_SERVER_IP"
    fi

    log_message "INFO" "Запуск первоначальной настройки (Mode: $WG_MODE, Port: $WG_PORT, Net: $WG_NET, ServerIP: $WG_SERVER_IP)"

    install_wireguard

    # iface уже должен быть определен в wg-setup.sh и передан сюда
    local iface="$PUBLIC_INTERFACE"
    if [[ -z "$iface" ]]; then
        log_message "ERROR" "Не удалось определить сетевой интерфейс (PUBLIC_INTERFACE пуста)"
        exit 1
    fi
    log_message "INFO" "Используем интерфейс: $iface"

    generate_server_keys
    generate_wg_config "$iface"

    enable_ip_forwarding
    open_firewall_port "$WG_PORT"

    systemctl enable "wg-quick@${WG_INTERFACE}"
    systemctl restart "wg-quick@${WG_INTERFACE}"

    # --- Создание config.env ---
    # Теперь вызываем update_config_file с правильными параметрами
    update_config_file "$WG_MODE" "$WG_PORT" "$WG_NET" "$WG_SERVER_IP" "$HOME_DNS_WG_IP" "$HOME_NET" "$SERVER_PUBLIC_IP" "$PUBLIC_INTERFACE" "$CLIENTS_DIR_DEFAULT" "$BACKUP_DIR_DEFAULT" "$LOG_FILE_DEFAULT"

    log_message "INFO" "WireGuard успешно настроен и config.env создан"
}


# ---------- АВТОЗАПУСК ПРИ ПРЯМОМ ВЫЗОВЕ ----------
# Если файл запущен напрямую, а не через source — выполняем initial_setup_main
# (Теперь это не используется, так как вызов идет через wg-setup.sh)
# if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
#     initial_setup_main
# fi
