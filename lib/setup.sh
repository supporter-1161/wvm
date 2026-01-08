#!/bin/bash

# --- Функции первоначальной настройки ---

# ================================
# initial_setup_main — ТОЧКА ВХОДА
# ================================
initial_setup_main() {
    log_message "INFO" "Запуск первоначальной настройки WireGuard"

    install_wireguard || return 1

    # Определяем публичный интерфейс
    PUBLIC_INTERFACE=$(get_public_interface)
    if [[ -z "$PUBLIC_INTERFACE" ]]; then
        log_message "ERROR" "Не удалось определить публичный интерфейс"
        return 1
    fi

    SERVER_PUBLIC_IP=$(curl -s ifconfig.me)
    if ! validate_ip "$SERVER_PUBLIC_IP"; then
        log_message "ERROR" "Не удалось определить публичный IP VPS"
        return 1
    fi

    generate_server_keys || return 1

    local server_private_key
    server_private_key=$(cat "$WG_PRIVATE_KEY_FILE")

    generate_wg_config \
        "$WG_MODE" \
        "$WG_PORT" \
        "$WG_SERVER_IP" \
        "$server_private_key" \
        "$HOME_DNS_WG_IP" \
        "$HOME_NET" \
        "$PUBLIC_INTERFACE" \
        "$WG_CONFIG_FILE" || return 1

    enable_ip_forwarding
    open_firewall_port "$WG_PORT"

    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0 || {
        log_message "ERROR" "wg-quick@wg0 не смог стартовать"
        return 1
    }

    SETUP_COMPLETED="true"
    save_config

    log_message "INFO" "Первоначальная настройка завершена успешно"
}

# ================================
# Генерация wg0.conf
# ================================
generate_wg_config() {
    local mode="$1"
    local port="$2"
    local server_ip="$3"
    local server_private_key="$4"
    local home_dns_wg_ip="$5"
    local home_net="$6"
    local interface="$7"
    local wg_config_path="$8"

    if [[ "$mode" == "full" && -z "$interface" ]]; then
        log_message "ERROR" "Full Tunnel требует указания публичного интерфейса"
        return 1
    fi

    log_message "INFO" "Генерация wg0.conf (mode=$mode, port=$port, iface=$interface)"

    cat > "$wg_config_path" <<EOF
[Interface]
Address = $server_ip/24
ListenPort = $port
PrivateKey = $server_private_key
EOF

    if [[ "$mode" == "split" ]]; then
        cat >> "$wg_config_path" <<EOF

PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
EOF
    else
        cat >> "$wg_config_path" <<EOF

PostUp = iptables -A FORWARD -i %i -o $interface -j ACCEPT; \
         iptables -A FORWARD -i $interface -o %i -j ACCEPT; \
         iptables -t nat -A POSTROUTING -s $server_ip/24 -o $interface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o $interface -j ACCEPT; \
           iptables -D FORWARD -i $interface -o %i -j ACCEPT; \
           iptables -t nat -D POSTROUTING -s $server_ip/24 -o $interface -j MASQUERADE
EOF
    fi

    cat >> "$wg_config_path" <<EOF

# ================= HOME GATEWAY =================
# Домашний шлюз добавляется ПОСЛЕ установки
# WireGuard не допускает [Peer] без PublicKey
#
# [Peer]
# PublicKey = <HOME_GATEWAY_PUBLIC_KEY>
# AllowedIPs = $home_dns_wg_ip/32, $home_net
#
# systemctl restart wg-quick@wg0
# ================================================
EOF

    chmod 600 "$wg_config_path"
    log_message "INFO" "wg0.conf создан: $wg_config_path"
}

# ================================
# Установка WireGuard
# ================================
install_wireguard() {
    log_message "INFO" "Установка WireGuard"
    apt-get update
    apt-get install -y wireguard
}

# ================================
# Генерация ключей сервера
# ================================
generate_server_keys() {
    local wg_dir="/etc/wireguard"
    mkdir -p "$wg_dir"
    chmod 700 "$wg_dir"

    umask 077
    wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey > "$WG_PUBLIC_KEY_FILE"
    umask 022

    chmod 600 "$WG_PRIVATE_KEY_FILE" "$WG_PUBLIC_KEY_FILE"
    log_message "INFO" "Серверные ключи сгенерированы"
}

