#!/bin/bash

# --- Функции для настройки домашнего шлюза ---

# --- Внутренние вспомогательные функции для gateway_config.sh ---

# --- Основные функции ---

# Функция генерации конфига для домашнего шлюза и обновления wg0.conf на VPS
configure_home_gateway() {
    log_message "INFO" "Запуск процедуры настройки домашнего шлюза."

    # Проверяем, была ли выполнена первоначальная настройка
    if [[ "$SETUP_COMPLETED" != "true" ]]; then
        log_message "ERROR" "Первоначальная настройка VPS не выполнена. Запустите сначала 'Первоначальная настройка'."
        echo "Ошибка: Первоначальная настройка VPS не выполнена."
        return 1
    fi

    # Загружаем переменные из config.env, если они еще не были загружены в основном скрипте
    # (хотя wg-setup.sh должен был их загрузить)
    local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
    local server_public_key_file="${WG_PUBLIC_KEY_FILE:-/etc/wireguard/public.key}"
    local server_public_key
    server_public_key=$(cat "$server_public_key_file")

    # Запрашиваем параметры у пользователя
    echo "=== Настройка домашнего шлюза ==="
    echo "Вам потребуется публичный ключ WireGuard-интерфейса на домашнем шлюзе."
    echo "Если он еще не сгенерирован, сделайте это на шлюзе командой:"
    echo "  wg genkey | tee privatekey | wg pubkey > publickey"
    echo "Затем прочитайте публичный ключ: cat publickey"
    echo

    read -p "Введите публичный ключ домашнего шлюза: " home_gateway_public_key
    # Простая проверка формата (32 байта в base64 = 44 символа + ==)
    if [[ ! "$home_gateway_public_key" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw48]=$ ]]; then
        log_message "ERROR" "Введен некорректный публичный ключ (ожидается 44-символьная строка base64)."
        return 1
    fi

    read -p "Введите WireGuard IP для домашнего шлюза (по умолчанию $HOME_DNS_WG_IP): " input_home_gw_wg_ip
    local home_gw_wg_ip="${input_home_gw_wg_ip:-$HOME_DNS_WG_IP}"
    if ! validate_ip "$home_gw_wg_ip"; then
        log_message "ERROR" "Неверный формат WireGuard IP для домашнего шлюза: $home_gw_wg_ip"
        return 1
    fi

    read -p "Введите LAN IP домашнего шлюза (по умолчанию 192.168.0.225): " input_home_gw_lan_ip
    local home_gw_lan_ip="${input_home_gw_lan_ip:-192.168.0.225}"
    if ! validate_ip "$home_gw_lan_ip"; then
        log_message "ERROR" "Неверный формат LAN IP для домашнего шлюза: $home_gw_lan_ip"
        return 1
    fi

    # Подтверждение
    echo
    echo "Проверьте введенные данные:"
    echo "Публичный ключ шлюза: $home_gateway_public_key"
    echo "WireGuard IP шлюза: $home_gw_wg_ip"
    echo "LAN IP шлюза: $home_gw_lan_ip"
    echo "Порт VPS (из настроек): $WG_PORT"
    echo "Публичный IP VPS (из настроек): $SERVER_PUBLIC_IP"
    echo "Пул VPN (из настроек): $WG_NET"
    echo "Домашняя сеть (из настроек): $HOME_NET"
    echo
    read -p "Продолжить настройку шлюза с этими параметрами? (y/N): " confirm_gw
    if [[ ! $confirm_gw =~ ^[Yy]$ ]]; then
        log_message "INFO" "Настройка домашнего шлюза отменена пользователем."
        return 0
    fi

    # --- Обновление wg0.conf на VPS ---
    log_message "INFO" "Обновление wg0.conf ($wg_config_path) для добавления домашнего шлюза."

    # Проверяем, существует ли уже запись для этого IP (защита от дублирования)
    if grep -q "# Peer: Home Gateway" "$wg_config_path" && grep -A 10 "# Peer: Home Gateway" "$wg_config_path" | grep -q "$home_gw_wg_ip"; then
        log_message "WARNING" "Запись для домашнего шлюза с IP $home_gw_wg_ip уже существует в wg0.conf. Обновление пропущено."
        echo "Предупреждение: Запись для шлюза с IP $home_gw_wg_ip уже существует."
        # Можно предложить обновить ключ, если IP совпадает, но для простоты пока так.
        return 0
    fi

    # Создаем бэкап wg0.conf перед изменением
    cp "$wg_config_path" "$wg_config_path.backup_before_gateway"
    log_message "INFO" "Создан бэкап wg0.conf: $wg_config_path.backup_before_gateway"

    # Добавляем пира для домашнего шлюза в конец файла
    # ВАЖНО: AllowedIPs для шлюза НЕ зависит от режима клиента, он всегда отвечает за WG_IP и HOME_NET
    cat >> "$wg_config_path" << EOF

# Peer: Home Gateway
[Peer]
PublicKey = $home_gateway_public_key
AllowedIPs = $home_gw_wg_ip/32, $HOME_NET

EOF

    log_message "INFO" "Добавлена запись для домашнего шлюза в wg0.conf."

    # Применение изменений к работающему интерфейсу
    wg syncconf wg0 <(wg-quick strip wg0)
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "Ошибка при применении изменений к интерфейсу wg0. Проверьте конфигурацию и бэкап $wg_config_path.backup_before_gateway."
        return 1
    fi

    log_message "INFO" "Изменения в wg0.conf применены к интерфейсу wg0."

    # --- Генерация конфига для домашнего шлюза ---
    local gateway_config_filename="wg-home-gateway.conf"
    local gateway_config_path="/etc/wireguard/$gateway_config_filename"

    log_message "INFO" "Генерация конфига для домашнего шлюза: $gateway_config_path"

    # Читаем шаблон или создаем напрямую
    # Для простоты создадим напрямую
    cat > "$gateway_config_path" << EOF
[Interface]
# Приватный ключ нужно вставить вручную после помещения файла на шлюз
# PrivateKey = <INSERT_PRIVATE_KEY_HERE_ON_GATEWAY_DEVICE>
Address = $home_gw_wg_ip/32
# DNS = $home_gw_lan_ip # Если хотите, чтобы шлюз использовал свой локальный DNS для запросов от VPS

[Peer]
PublicKey = $server_public_key
Endpoint = $SERVER_PUBLIC_IP:$WG_PORT
AllowedIPs = $WG_NET, $HOME_NET
PersistentKeepalive = 25

# Правила для проброса трафика из VPN в домашнюю сеть
# Замените eth0 на реальный LAN интерфейс шлюза
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s $WG_NET -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s $WG_NET -o eth0 -j MASQUERADE

EOF

    chmod 600 "$gateway_config_path"
    log_message "INFO" "Конфиг для домашнего шлюза создан: $gateway_config_path"

    # --- Инструкция пользователю ---
    echo
    echo "=== Настройка домашнего шлюза завершена ==="
    echo "1. Скопируйте файл конфигурации на ваш домашний шлюз:"
    echo "   scp $gateway_config_path user@home_gateway_ip:/tmp/"
    echo "2. На домашнем шлюзе:"
    echo "   a. Вставьте приватный ключ WireGuard в файл $gateway_config_filename"
    echo "      (замените '<INSERT_PRIVATE_KEY_HERE_ON_GATEWAY_DEVICE>'):"
    echo "      echo 'YOUR_PRIVATE_KEY_HERE' > /etc/wireguard/private.key"
    echo "      chmod 600 /etc/wireguard/private.key"
    echo "      # Затем вставьте его в $gateway_config_filename"
    echo "   b. Переместите файл в /etc/wireguard/:"
    echo "      sudo mv /tmp/$gateway_config_filename /etc/wireguard/"
    echo "   c. Замените 'eth0' в PostUp/PostDown на реальный LAN-интерфейс шлюза (например, br0, lan0)."
    echo "   d. Запустите интерфейс:"
    echo "      sudo wg-quick up $gateway_config_filename"
    echo "   e. (Опционально) Включите автозапуск:"
    echo "      sudo systemctl enable wg-quick@$gateway_config_filename"
    echo "3. Проверьте соединение (на VPS):"
    echo "   sudo ./wg-setup.sh -> 'Мониторинг' -> 'Проверить доступ к домашней сети'"
    echo "==============================================="
}

# --- Основная функция для вызова из главного скрипта ---
configure_home_gateway_main() {
    log_message "INFO" "Вызов процедуры настройки домашнего шлюза"
    configure_home_gateway
}

