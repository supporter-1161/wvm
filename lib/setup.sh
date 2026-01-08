#!/bin/bash

# --- Функции первоначальной настройки ---

# Генерация конфига wg0.conf на основе режима
# КРИТИЧЕСКОЕ ИЗМЕНЕНИЕ:
#  - В конфиге НЕТ ни одного [Peer] без PublicKey
#  - Домашний шлюз добавляется ТОЛЬКО как комментарий-шаблон
#  - Реальный [Peer] создаётся отдельной функцией

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

    # ТОЛЬКО КОММЕНТАРИЙ — НЕ [Peer]
    cat >> "$wg_config_path" <<EOF

# ================= HOME GATEWAY =================
# Домашний шлюз НЕ добавляется автоматически.
# WireGuard НЕ допускает [Peer] без PublicKey.
#
# Когда публичный ключ шлюза будет известен — добавьте:
#
# [Peer]
# PublicKey = <HOME_GATEWAY_PUBLIC_KEY>
# AllowedIPs = $home_dns_wg_ip/32, $home_net
#
# После этого выполните:
#   systemctl restart wg-quick@wg0
# ================================================
EOF

    chmod 600 "$wg_config_path"
    log_message "INFO" "wg0.conf успешно сгенерирован: $wg_config_path"
}

# Установка WireGuard
install_wireguard() {
    log_message "INFO" "Установка wireguard"
    apt-get update
    apt-get install -y wireguard
}

# Генерация серверных ключей
generate_server_keys() {
    local wg_dir="/etc/wireguard"
    local private_key_file="${WG_PRIVATE_KEY_FILE:-$wg_dir/private.key}"
    local public_key_file="${WG_PUBLIC_KEY_FILE:-$wg_dir/public.key}"

    mkdir -p "$wg_dir"
    chmod 700 "$wg_dir"

    umask 077
    wg genkey | tee "$private_key_file" | wg pubkey > "$public_key_file"
    umask 022

    chmod 600 "$private_key_file" "$public_key_file"

    log_message "INFO" "Серверные ключи сгенерированы"
}

