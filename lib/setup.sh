#!/bin/bash

# --- Функции первоначальной настройки ---

# --- Внутренние вспомогательные функции для setup.sh ---

# --- Внутренние вспомогательные функции для setup.sh ---

# Функция генерации конфига wg0.conf на основе режима
generate_wg_config() {
    local mode="$1"
    local port="$2"
    local server_ip="$3"
    local server_private_key="$4"
    local home_dns_wg_ip="$5"
    local home_net="$6"
    local interface="$7"
    local wg_config_path="$8"

    # Проверяем, что интерфейс определен, если mode=full
    if [[ "$mode" == "full" && -z "$interface" ]]; then
        log_message "ERROR" "Не могу сгенерировать конфиг для Full Tunnel: не определен публичный интерфейс."
        return 1
    fi

    log_message "DEBUG" "Начинаю генерацию wg0.conf. Mode: $mode, Port: $port, ServerIP: $server_ip, Interface: $interface, HomeDNSIP: $home_dns_wg_ip, HomeNet: $home_net"

    # Начинаем формировать конфиг
    local config_content="[Interface]
Address = $server_ip/24
ListenPort = $port
PrivateKey = $server_private_key

"

    # Добавляем PostUp/PostDown правила в зависимости от режима
    if [[ "$mode" == "split" ]]; then
        log_message "INFO" "Генерация конфига wg0.conf для режима Split Tunnel."
        config_content+="PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

"
    elif [[ "$mode" == "full" ]]; then
        log_message "INFO" "Генерация конфига wg0.conf для режима Full Tunnel."
        # Используем переданный интерфейс, который теперь должен быть чистым
        config_content+="PostUp = iptables -A FORWARD -i %i -o $interface -j ACCEPT; iptables -A FORWARD -i $interface -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -s $server_ip/24 -o $interface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o $interface -j ACCEPT; iptables -D FORWARD -i $interface -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -s $server_ip/24 -o $interface -j MASQUERADE

"
    else
        log_message "ERROR" "Неизвестный режим: $mode"
        return 1
    fi

    # Добавляем пира для домашнего шлюза - это критично и НЕ зависит от режима клиента!
    # Он всегда должен отвечать за WG_IP домашнего шлюза и за HOME_NET.
    # Обратите внимание: PublicKey и AllowedIPs записываются как плейсхолдеры!
    config_content+="# Peer: Домашний DNS-сервер / шлюз
# ВАЖНО: Этот пир НЕ для клиента, а для постоянного подключения домашнего шлюза.
# PublicKey домашнего шлюза должен быть добавлен АДМИНИСТРАТОРОМ вручную в этот файл ПОСЛЕ настройки WVM.
# Затем нужно перезапустить wg-quick@wg0.
# AllowedIPs для этого пира НЕ меняется в зависимости от режима VPS (split/full)
[Peer]
# PublicKey = <PUBLIC_KEY_OF_HOME_GATEWAY>
# AllowedIPs = $home_dns_wg_ip/32, $home_net
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# ЗАМЕНИТЕ ВЫШЕ строчки '# PublicKey = ...' и '# AllowedIPs = ...' на настоящие:
# PublicKey = ACTUAL_PUBLIC_KEY_HERE
# AllowedIPs = $home_dns_wg_ip/32, $home_net
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

"

    log_message "DEBUG" "Сгенерированное содержимое wg0.conf (до записи):\n$config_content"

    # Записываем сгенерированное содержимое в файл
    echo -n "$config_content" > "$wg_config_path"

    log_message "INFO" "Конфиг wg0.conf сгенерирован в $wg_config_path (без клиентов)."
    log_message "INFO" "НЕ ЗАБУДЬТЕ: Вручную добавить PublicKey домашнего шлюза в $wg_config_path и перезапустить wg-quick@wg0."
    return 0
}

# --- Основные функции ---

# Установка WireGuard
install_wireguard() {
    log_message "INFO" "Проверка и установка WireGuard (wireguard-tools)..."
    if command -v apt-get &> /dev/null; then
        apt-get update
        apt-get install -y wireguard
    else
        log_message "ERROR" "Неизвестный менеджер пакетов. Установите wireguard-tools вручную."
        return 1
    fi
    log_message "INFO" "WireGuard установлен."
}

# Генерация ключей сервера
generate_server_keys() {
    local wg_dir="/etc/wireguard"
    local private_key_file="${WG_PRIVATE_KEY_FILE:-$wg_dir/private.key}"
    local public_key_file="${WG_PUBLIC_KEY_FILE:-$wg_dir/public.key}"

    log_message "INFO" "Генерация ключей сервера в $wg_dir..."

    # Создаем директорию, если не существует
    mkdir -p "$wg_dir"
    chmod 700 "$wg_dir" # Убедимся в правах

    # Генерируем ключи с правами 0600
    umask 077
    wg genkey | tee "$private_key_file" | wg pubkey > "$public_key_file"
    local ret=$?
    umask 022 # Восстанавливаем стандартную umask

    if [[ $ret -ne 0 ]]; then
        log_message "ERROR" "Ошибка при генерации ключей сервера."
        return $ret
    fi

    chmod 600 "$private_key_file" "$public_key_file"
    log_message "INFO" "Ключи сервера сгенерированы и права установлены."
}

# Настройка WireGuard сервера
configure_wireguard_server() {
    local mode="$1"
    local port="$2"
    local wg_net="$3"
    local home_dns_wg_ip="$4"
    local home_net="$5"
    local public_interface="$6"
    local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"

    local server_ip=$(echo "$wg_net" | sed 's/\/24//') # Предполагаем /24, извлекаем x.x.x.0
    server_ip="${server_ip%.*}.1" # x.x.x.1

    local server_private_key
    server_private_key=$(cat "${WG_PRIVATE_KEY_FILE:-/etc/wireguard/private.key}")

    generate_wg_config "$mode" "$port" "$server_ip" "$server_private_key" "$home_dns_wg_ip" "$home_net" "$public_interface" "$wg_config_path"
    local ret=$?
    if [[ $ret -ne 0 ]]; then
        log_message "ERROR" "Ошибка при генерации конфига wg0.conf."
        return $ret
    fi
}

# Настройка фаервола (пытаемся определить UFW, иначе используем iptables)
configure_firewall() {
    local port="$1"
    log_message "INFO" "Настройка фаервола для открытия порта $port/udp..."

    if command -v ufw &> /dev/null; then
        log_message "INFO" "Обнаружен UFW. Открытие порта через UFW."
        ufw allow "$port"/udp
        # Проверяем статус UFW и включаем, если отключен, для сохранения правил
        if ! ufw status | grep -q "Status: active"; then
            log_message "INFO" "UFW не активен. Попытка включения (это может потребовать подтверждения)."
            # ufw --force enable # Это может прервать SSH сессию, будьте осторожны. Пока не включаем автоматически.
            # Просто предупреждаем.
            log_message "WARNING" "UFW обнаружен, но не активен. Откройте порт вручную или включите UFW (ufw enable)."
        fi
    else
        log_message "INFO" "UFW не найден. Открытие порта через iptables."
        iptables -A INPUT -p udp --dport "$port" -j ACCEPT
        # iptables правила не сохраняются автоматически. Рассмотреть использование iptables-persistent.
        # Для простоты пока не реализуем сохранение, пользователь должен сам позаботиться об этом.
        log_message "INFO" "Правило iptables добавлено. Рассмотрите использование iptables-persistent для сохранения после перезагрузки."
    fi
}

# Включение IP forwarding
enable_ip_forwarding() {
    log_message "INFO" "Включение IP forwarding..."
    # Проверяем текущее значение
    local current_value
    current_value=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [[ "$current_value" -eq 1 ]]; then
        log_message "INFO" "IP forwarding уже включен."
        return 0
    fi

    # Временно включаем
    sysctl -w net.ipv4.ip_forward=1
    # Постоянно включаем через /etc/sysctl.conf
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    else
        log_message "INFO" "Запись net.ipv4.ip_forward=1 уже присутствует в /etc/sysctl.conf."
    fi
    log_message "INFO" "IP forwarding включен."
}

# Запуск и включение автозапуска WireGuard
start_and_enable_wireguard() {
    local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
    local config_name=$(basename "$wg_config_path" .conf)

    log_message "INFO" "Запуск и включение автозапуска WireGuard интерфейса $config_name..."

    # Проверяем, существует ли файл конфига
    if [[ ! -f "$wg_config_path" ]]; then
        log_message "ERROR" "Файл конфига $wg_config_path не найден. Невозможно запустить."
        return 1
    fi

    # Запускаем интерфейс
    wg-quick up "$config_name"
    local ret=$?
    if [[ $ret -ne 0 ]]; then
        log_message "ERROR" "Ошибка при запуске WireGuard интерфейса $config_name."
        return $ret
    fi

    # Включаем автозапуск через systemd
    systemctl enable "wg-quick@$config_name"
    ret=$?
    if [[ $ret -ne 0 ]]; then
        log_message "WARNING" "Предупреждение: Ошибка при включении автозапуска для wg-quick@$config_name (systemctl enable)."
        # Не считаем это критичной ошибкой, но логируем.
    else
        log_message "INFO" "Автозапуск для wg-quick@$config_name включен."
    fi

    log_message "INFO" "WireGuard интерфейс $config_name запущен и автозапуск настроен."
}

# Обновление файла конфигурации скрипта (config.env)
update_config_file() {
    local new_config_file="${CONFIG_FILE:-/etc/wireguard/config.env}"

    log_message "INFO" "Обновление файла конфигурации скрипта: $new_config_file"

    # Создаем директорию для config.env, если не существует
    local config_dir=$(dirname "$new_config_file")
    mkdir -p "$config_dir"

    # Записываем обновленные значения в новый файл
    cat > "$new_config_file" << EOF
# --- Обновленная конфигурация скрипта wg-setup.sh после установки ---

# Основные настройки
WG_MODE="$WG_MODE"
WG_PORT="$WG_PORT"
WG_NET="$WG_NET"
WG_SERVER_IP="$WG_SERVER_IP"

# Домашняя сеть
HOME_NET="$HOME_NET"
HOME_DNS_WG_IP="$HOME_DNS_WG_IP"

# Сеть клиентов
CLIENT_NET_START="$CLIENT_NET_START"
CLIENT_NET_END="$CLIENT_NET_END"

# VPS настройки
SERVER_PUBLIC_IP="$SERVER_PUBLIC_IP"
PUBLIC_INTERFACE="$PUBLIC_INTERFACE"

# Пути (на целевой системе VPS)
WG_CONFIG_FILE="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
WG_PRIVATE_KEY_FILE="${WG_PRIVATE_KEY_FILE:-/etc/wireguard/private.key}"
WG_PUBLIC_KEY_FILE="${WG_PUBLIC_KEY_FILE:-/etc/wireguard/public.key}"
CLIENTS_DIR="${CLIENTS_DIR:-/etc/wireguard/clients}"
BACKUP_DIR="${BACKUP_DIR:-/etc/wireguard/backup}"
LOG_FILE="${LOG_FILE:-/etc/wireguard/logs/setup.log}"

# Статус установки
SETUP_COMPLETED="true"
EOF

    chmod 600 "$new_config_file"
    log_message "INFO" "Файл конфигурации $new_config_file обновлен и права установлены (0600)."
}


# --- Основная функция первоначальной настройки ---
initial_setup_main() {
    log_message "INFO" "Начало процедуры первоначальной настройки."

    # 1. Запрашиваем параметры у пользователя
    echo "=== Первоначальная настройка WireGuard VPN ==="

    # Режим
    while true; do
        read -p "Выберите режим работы (1 - Split Tunnel, 2 - Full Tunnel): " mode_choice
        case $mode_choice in
            1) WG_MODE="split"; break ;;
            2) WG_MODE="full"; break ;;
            *) echo "Неверный выбор. Введите 1 или 2." ;;
        esac
    done
    log_message "INFO" "Выбран режим: $WG_MODE"

    # Порт
    read -p "Введите порт WireGuard (по умолчанию 29717): " input_port
    WG_PORT="${input_port:-29717}"
    if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || [[ "$WG_PORT" -lt 1 ]] || [[ "$WG_PORT" -gt 65535 ]]; then
        log_message "ERROR" "Неверный формат порта: $WG_PORT"
        return 1
    fi
    log_message "INFO" "Выбран порт: $WG_PORT"

    # Пул VPN-адресов
    read -p "Введите пул VPN-адресов (CIDR, по умолчанию 10.99.0.0/24): " input_wg_net
    WG_NET="${input_wg_net:-10.99.0.0/24}"
    if ! validate_cidr "$WG_NET"; then
        log_message "ERROR" "Неверный формат CIDR для пула: $WG_NET"
        return 1
    fi
    log_message "INFO" "Выбран пул: $WG_NET"

    # IP домашнего DNS в VPN
    read -p "Введите IP домашнего DNS-сервера в VPN (по умолчанию 10.99.0.100): " input_home_dns
    HOME_DNS_WG_IP="${input_home_dns:-10.99.0.100}"
    if ! validate_ip "$HOME_DNS_WG_IP"; then
        log_message "ERROR" "Неверный формат IP для домашнего DNS: $HOME_DNS_WG_IP"
        return 1
    fi
    log_message "INFO" "Выбран IP домашнего DNS в VPN: $HOME_DNS_WG_IP"

    # Диапазон домашней сети
    read -p "Введите диапазон домашней сети (CIDR, по умолчанию 192.168.0.0/24): " input_home_net
    HOME_NET="${input_home_net:-192.168.0.0/24}"
    if ! validate_cidr "$HOME_NET"; then
        log_message "ERROR" "Неверный формат CIDR для домашней сети: $HOME_NET"
        return 1
    fi
    log_message "INFO" "Выбран диапазон домашней сети: $HOME_NET"

    # IP сервера в VPN (обычно .1 от пула)
    WG_SERVER_IP=$(echo "$WG_NET" | sed 's/\/24//')
    WG_SERVER_IP="${WG_SERVER_IP%.*}.1"
    log_message "INFO" "IP сервера в VPN определен как: $WG_SERVER_IP"

    # Начальный и конечный IP для клиентов (берем из пула, исключая сервер и DNS)
    CLIENT_NET_START="${WG_SERVER_IP%.*}.2"  # x.x.x.2
    CLIENT_NET_END="${WG_SERVER_IP%.*}.254" # x.x.x.254
    log_message "INFO" "Пул IP для клиентов: $CLIENT_NET_START - $CLIENT_NET_END"

    # Публичный IP VPS
    read -p "Введите публичный IP-адрес VPS: " SERVER_PUBLIC_IP
    if ! validate_ip "$SERVER_PUBLIC_IP"; then
        log_message "ERROR" "Неверный формат публичного IP: $SERVER_PUBLIC_IP"
        return 1
    fi
    log_message "INFO" "Публичный IP VPS: $SERVER_PUBLIC_IP"

    # Публичный интерфейс VPS
    detected_interface=$(get_public_interface) # Вызов функции без логирования внутри
    if [[ -n "$detected_interface" ]]; then
        log_message "INFO" "Определен публичный интерфейс: $detected_interface" # Логируем результат снаружи
        read -p "Определен публичный интерфейс: $detected_interface. Использовать его? (Y/n): " confirm_interface
        if [[ $confirm_interface =~ ^[Nn]$ ]]; then
            read -p "Введите публичный интерфейс вручную: " input_interface
            PUBLIC_INTERFACE="$input_interface"
            log_message "INFO" "Публичный интерфейс (вручную): $PUBLIC_INTERFACE" # Логируем ввод
        else
            PUBLIC_INTERFACE="$detected_interface"
        fi
    else
        log_message "WARNING" "Не удалось автоматически определить публичный интерфейс." # Логируем снаружи
        read -p "Введите публичный интерфейс вручную (например, eth0, ens3): " input_interface
        PUBLIC_INTERFACE="$input_interface"
        log_message "INFO" "Публичный интерфейс (вручную): $PUBLIC_INTERFACE" # Логируем ввод
    fi
    if [[ -z "$PUBLIC_INTERFACE" ]]; then
        log_message "ERROR" "Публичный интерфейс не может быть пустым."
        return 1
    fi
    # Убедимся, что PUBLIC_INTERFACE не содержит лишних символов (на всякий случай)
    PUBLIC_INTERFACE=$(echo "$PUBLIC_INTERFACE" | tr -d '\r\n')

    # Подтверждение
    echo
    echo "Проверьте введенные данные:"
    echo "Режим: $WG_MODE"
    echo "Порт: $WG_PORT"
    echo "Пул VPN: $WG_NET"
    echo "IP DNS в VPN: $HOME_DNS_WG_IP"
    echo "Домашняя сеть: $HOME_NET"
    echo "Публичный IP VPS: $SERVER_PUBLIC_IP"
    echo "Публичный интерфейс: $PUBLIC_INTERFACE" # Выводим чистое значение
    echo
    read -p "Начать настройку с этими параметрами? (y/N): " confirm_setup
    if [[ ! $confirm_setup =~ ^[Yy]$ ]]; then
        log_message "INFO" "Настройка отменена пользователем."
        return 0
    fi

    # 2. Выполняем шаги настройки
    # Установка WireGuard
    install_wireguard || return $?

    # --- Создание директорий ПОСЛЕ определения переменных, но ДО их использования ---
    # В момент вызова install_wireguard переменные WG_* еще не определены,
    # и они используют значения по умолчанию из functions.sh.
    # mkdir с пустой строкой в переменной приведет к ошибке.
    # Но в install_wireguard mkdir не вызывается.
    # mkdir вызывается в generate_server_keys (с жестким /etc/wireguard) и update_config_file (с жестким /etc/wireguard).
    # Однако, в add_client (из client_management.sh) используется CLIENTS_DIR, BACKUP_DIR, LOG_FILE.
    # Их значения по умолчанию определяются ДО загрузки config.env, т.е. до вызова initial_setup_main.
    # Поэтому, чтобы они были правильными для *всех* последующих вызовов, нужно:
    # A. Либо обновить config.env ДО создания директорий (но тогда он будет пустым).
    # B. Либо создать директории ПОСЛЕ обновления config.env.
    # C. Либо передавать пути как аргументы во все функции.
    # D. Либо определить пути в initial_setup_main и передать в update_config_file.
    # Вариант B кажется наиболее подходящим для текущей архитектуры.
    # Мы создаем директории ПОСЛЕ обновления переменных, но ПЕРЕД их использованием в других местах.
    # Но update_config_file вызывается в конце. Значит, нужно создать директории в конце initial_setup_main или перед update_config_file.
    # Лучше всего: создать директории сразу после установки wireguard и до вызова других функций, использующих пути.
    # Но нам нужно знать правильные пути. Правильные пути - это те, которые будут записаны в config.env.
    # Для этого нужно определить все переменные (как сделано выше).
    # Затем, создать директории с этими переменными (если они были определены).
    # Но в этот момент config.env еще не создан.
    # Используем значения, которые будут записаны в config.env, т.е. переменные, определенные выше.

    log_message "INFO" "Создание необходимых директорий..."
    # Используем переменные, определенные выше в initial_setup_main
    local final_clients_dir="${CLIENTS_DIR:-/etc/wireguard/clients}"
    local final_backup_dir="${BACKUP_DIR:-/etc/wireguard/backup}"
    local final_log_file="${LOG_FILE:-/etc/wireguard/logs/setup.log}"
    local final_log_dir=$(dirname "$final_log_file")

    mkdir -p "$final_clients_dir" "$final_backup_dir" "$final_log_dir"

    # Генерация ключей сервера
    generate_server_keys || return $?

    # Настройка WireGuard сервера (генерация wg0.conf)
    configure_wireguard_server "$WG_MODE" "$WG_PORT" "$WG_NET" "$HOME_DNS_WG_IP" "$HOME_NET" "$PUBLIC_INTERFACE" || return $?

    # Настройка фаервола
    configure_firewall "$WG_PORT" || return $?

    # Включение IP forwarding
    enable_ip_forwarding || return $?

    # Запуск и включение автозапуска
    start_and_enable_wireguard || return $?

    # Обновление config.env
    update_config_file || return $?

    log_message "INFO" "Первоначальная настройка успешно завершена!"
    echo
    echo "Настройка завершена!"
    echo "- Сервер WireGuard запущен и включен в автозапуск."
    echo "- Файл конфигурации сохранен в /etc/wireguard/config.env"
    echo "- Теперь вы можете добавить клиентов через меню управления."
    echo "- Не забудьте настроить домашний шлюз (Peer) вручную в /etc/wireguard/wg0.conf"
    echo "  с его публичным ключом и AllowedIPs = $HOME_DNS_WG_IP/32, $HOME_NET"
    echo "  (см. инструкцию в исходной документации)."
    echo
    return 0
}
