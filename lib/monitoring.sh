#!/bin/bash
# --- Функции мониторинга ---
# --- Внутренные вспомогательные функции для monitoring.sh ---
# --- Основные функции ---
# Показать статус WireGuard
show_wireguard_status() {
    local interface="wg0"
    log_message "INFO" "Проверка статуса WireGuard интерфейса: $interface"

    if command -v wg &> /dev/null; then
        echo "--- Статус wg show $interface ---"
        wg show "$interface"
        echo "----------------------------------"
    else
        log_message "ERROR" "Команда 'wg' не найдена. Убедитесь, что установлен wireguard-tools."
        echo "Команда 'wg' не найдена. Убедитесь, что установлен wireguard-tools."
    fi
}

# Показать подключенных пиры (активные соединения)
show_connected_peers() {
    local interface="wg0"
    log_message "INFO" "Проверка активных подключений к интерфейсу: $interface"

    if command -v wg &> /dev/null; then
        echo "--- Активные пиры (wg show $interface) ---"
        # wg show выводит таблицу с информацией о пирах, включая latest handshake
        wg show "$interface" transfer endpoint allowed-ips # Показываем передачу данных, эндпоинт и разрешенные IP
        echo "------------------------------------------"
    else
        log_message "ERROR" "Команда 'wg' не найдена. Убедитесь, что установлен wireguard-tools."
        echo "Команда 'wg' не найдена. Убедитесь, что установлен wireguard-tools."
    fi
}

# Проверить доступность домашнего DNS (через ping, если туннель активен)
check_home_network_access() {
    # Используем переменные из config.env, если они загружены
    local home_dns_wg_ip="${HOME_DNS_WG_IP:-10.99.0.100}" # Значение по умолчанию на случай, если config.env не загружен
    local home_gw_lan_ip_default="192.168.0.225" # IP LAN шлюза по умолчанию
    local home_gw_lan_ip="${HOME_GW_LAN_IP:-$home_gw_lan_ip_default}" # Используем из config.env, если задано, иначе по умолчанию

    log_message "INFO" "Проверка доступности домашнего DNS в VPN ($home_dns_wg_ip) и LAN IP шлюза ($home_gw_lan_ip)"

    # Проверим, запущен ли интерфейс wg0
    if ! wg show wg0 > /dev/null 2>&1; then
        log_message "WARNING" "Интерфейс wg0 не активен. Проверка ping невозможна."
        echo "Интерфейс wg0 не активен. Проверка ping невозможна."
        return 1
    fi

    echo "Пингуем $home_dns_wg_ip (домашний DNS через VPN)..."
    if ping -c 3 -W 5 "$home_dns_wg_ip" &> /dev/null; then
        log_message "INFO" "Доступ к $home_dns_wg_ip подтвержден."
        echo "OK: $home_dns_wg_ip (VPN IP шлюза) отвечает на ping."
    else
        log_message "WARNING" "Нет ответа от $home_dns_wg_ip. Возможны проблемы с доступом к домашней сети через VPN."
        echo "ПРЕДУПРЕЖДЕНИЕ: $home_dns_wg_ip (VPN IP шлюза) не отвечает на ping. Проверьте настройки туннеля или состояние домашнего шлюза."
    fi

    echo "Пингуем $home_gw_lan_ip (LAN IP шлюза)..."
    if ping -c 3 -W 5 "$home_gw_lan_ip" &> /dev/null; then
        log_message "INFO" "Доступ к $home_gw_lan_ip подтвержден."
        echo "OK: $home_gw_lan_ip (LAN IP шлюза) отвечает на ping."
    else
        log_message "WARNING" "Нет ответа от $home_gw_lan_ip. Возможны проблемы с доступом к домашней сети или шлюз не отвечает."
        echo "ПРЕДУПРЕЖДЕНИЕ: $home_gw_lan_ip (LAN IP шлюза) не отвечает на ping. Проверьте состояние домашнего шлюза или его настройки."
    fi
}


# Показать основные маршруты (например, маршрут к домашней сети)
show_routes() {
    # Используем переменную HOME_NET из config.env, если она загружена
    local home_net="${HOME_NET:-192.168.0.0/24}" # Значение по умолчанию
    log_message "INFO" "Показ маршрутов (ip route show)"

    echo "--- Таблица маршрутизации (ip route show) ---"
    ip route show
    echo "---------------------------------------------"
    echo
    echo "--- Маршрут к домашней сети ($home_net) ---"
    # Показываем конкретный маршрут к домашней сети
    ip route show match "$home_net"
    if [[ $? -ne 0 ]]; then
        echo "(маршрут к $home_net не найден или не установлен через этот скрипт)"
    fi
    echo "---------------------------------------------"
}

# --- Основное меню мониторинга ---
monitoring_menu() {
    while true; do
        echo
        echo "=== Мониторинг ==="
        echo "1. Показать статус WireGuard"
        echo "2. Показать подключенные пиры"
        echo "3. Проверить доступ к домашней сети (ping)"
        echo "4. Показать маршруты"
        echo "5. Вернуться в главное меню"
        echo "=================="
        read -p "Выберите действие (1-5): " choice

        case $choice in
            1)
                log_message "INFO" "Выбран пункт меню: Показать статус WireGuard"
                show_wireguard_status
                ;;
            2)
                log_message "INFO" "Выбран пункт меню: Показать подключенные пиры"
                show_connected_peers
                ;;
            3)
                log_message "INFO" "Выбран пункт меню: Проверить доступ к домашней сети"
                check_home_network_access
                ;;
            4)
                log_message "INFO" "Выбран пункт меню: Показать маршруты"
                show_routes
                ;;
            5)
                log_message "INFO" "Возврат в главное меню из мониторинга"
                return 0
                ;;
            *)
                echo "Неверный выбор. Пожалуйста, введите число от 1 до 5."
                ;;
        esac
    done
}
