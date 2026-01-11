#!/bin/bash
# --- Функции управления клиентами ---

# --- Внутренние вспомогательные функции для client_management.sh ---

# Функция генерации клиентских конфигов из шаблонов
generate_client_configs() {
    local name="$1"
    local client_ip="$2"
    local client_private_key="$3"
    local server_public_key="$4"
    local server_endpoint_ip="$5"
    local server_port="$6"
    local wg_net="$7"
    local home_net="$8"
    local home_dns_wg_ip="$9"
    local clients_dir="${CLIENTS_DIR:-/etc/wireguard/clients}"

    log_message "INFO" "Генерация конфигов для клиента $name (IP: $client_ip)"

    # --- ГАРАНТИРУЕМ СУЩЕСТВОВАНИЕ ДИРЕКТОРИИ ---
    mkdir -p "$clients_dir"

    local client_split_config="$clients_dir/${name}-split.conf"
    local client_full_config="$clients_dir/${name}-full.conf"

    # Читаем шаблоны
    local split_template_content
    local full_template_content
    split_template_content=$(<"$TEMPLATE_DIR/client-split.template")
    full_template_content=$(<"$TEMPLATE_DIR/client-full.template")

    # Заменяем плейсхолдеры в шаблонах
    # Для Split
    local split_config_final
    split_config_final="${split_template_content//CLIENT_PRIVATE_KEY/$client_private_key}"
    split_config_final="${split_config_final//CLIENT_IP/$client_ip}"
    split_config_final="${split_config_final//SERVER_PUBLIC_KEY/$server_public_key}"
    split_config_final="${split_config_final//SERVER_PUBLIC_IP/$server_endpoint_ip}"
    split_config_final="${split_config_final//WG_PORT/$server_port}"
    split_config_final="${split_config_final//WG_NET/$wg_net}"
    split_config_final="${split_config_final//HOME_NET/$home_net}"
    split_config_final="${split_config_final//HOME_DNS_WG_IP/$home_dns_wg_ip}"

    # Для Full
    local full_config_final
    full_config_final="${full_template_content//CLIENT_PRIVATE_KEY/$client_private_key}"
    full_config_final="${full_config_final//CLIENT_IP/$client_ip}"
    full_config_final="${full_config_final//SERVER_PUBLIC_KEY/$server_public_key}"
    full_config_final="${full_config_final//SERVER_PUBLIC_IP/$server_endpoint_ip}"
    full_config_final="${full_config_final//WG_PORT/$server_port}"
    full_config_final="${full_config_final//WG_NET/$wg_net}"
    full_config_final="${full_config_final//HOME_NET/$home_net}"
    full_config_final="${full_config_final//HOME_DNS_WG_IP/$home_dns_wg_ip}"

    # Записываем готовые конфиги
    echo "$split_config_final" > "$client_split_config"
    echo "$full_config_final" > "$client_full_config"

    # Устанавливаем права
    chmod 600 "$client_split_config" "$client_full_config"
    log_message "INFO" "Конфиги клиента $name созданы: $client_split_config, $client_full_config"
}

# --- Основные функции ---

# Добавление клиента
add_client() {
    local name="$1"
    local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
    local wg_private_key_path="${WG_PRIVATE_KEY_FILE:-/etc/wireguard/private.key}"
    local wg_public_key_path="${WG_PUBLIC_KEY_FILE:-/etc/wireguard/public.key}"

    log_message "INFO" "Добавление клиента: $name"

    # Проверка на допустимое имя (без пробелов, слэшей, двоеточий и т.п.)
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_message "ERROR" "Недопустимое имя клиента: $name. Используйте только латинские буквы, цифры, тире и подчеркивание."
        return 1
    fi

    # Проверка, существует ли клиент уже (проверяем файлы конфигов)
    local clients_dir="${CLIENTS_DIR:-/etc/wireguard/clients}"
    if [[ -f "$clients_dir/${name}-split.conf" ]] || [[ -f "$clients_dir/${name}-full.conf" ]]; then
        log_message "ERROR" "Клиент с именем $name уже существует (найдены файлы конфигов)."
        return 1
    fi

    # Получение следующего свободного IP
    local client_ip
    client_ip=$(get_next_client_ip)
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "Не удалось получить свободный IP для клиента $name."
        return 1
    fi

    # Генерация ключей клиента (во временной папке для безопасности)
    local temp_dir
    temp_dir=$(mktemp -d)
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "Не удалось создать временную папку для ключей клиента."
        return 1
    fi

    local client_private_key_file="$temp_dir/client_private.key"
    local client_public_key_file="$temp_dir/client_public.key"

    umask 077
    wg genkey | tee "$client_private_key_file" | wg pubkey > "$client_public_key_file"
    local ret=$?
    umask 022
    if [[ $ret -ne 0 ]]; then
        log_message "ERROR" "Ошибка при генерации ключей клиента $name."
        rm -rf "$temp_dir"
        return $ret
    fi

    local client_private_key
    local client_public_key
    client_private_key=$(cat "$client_private_key_file")
    client_public_key=$(cat "$client_public_key_file")

    # Чтение публичного ключа сервера
    local server_public_key
    server_public_key=$(cat "$wg_public_key_path")

    # Добавление пира в wg0.conf
    log_message "INFO" "Добавление пира для $name в $wg_config_path"
    cat >> "$wg_config_path" << EOF
# Peer: $name
[Peer]
PublicKey = $client_public_key
AllowedIPs = $client_ip/32
EOF

    # Применение изменений к работающему интерфейсу
    wg syncconf wg0 <(wg-quick strip wg0)
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "Ошибка при применении изменений к интерфейсу wg0. Проверьте конфигурацию."
        # Откатываем изменения в конфиге, если применились
        # Это сложно сделать атомарно, поэтому просто логируем и рекомендуем ручное вмешательство
        log_message "WARNING" "Конфигурация wg0.conf может быть повреждена. Проверьте и исправьте вручную."
        rm -rf "$temp_dir"
        return 1
    fi

    # Генерация клиентских конфигов
    generate_client_configs "$name" "$client_ip" "$client_private_key" "$server_public_key" "$SERVER_PUBLIC_IP" "$WG_PORT" "$WG_NET" "$HOME_NET" "$HOME_DNS_WG_IP"

    # Удаление временных ключей
    rm -rf "$temp_dir"

    log_message "INFO" "Клиент $name успешно добавлен (IP: $client_ip)."
    echo "Клиент $name добавлен успешно."
    echo "Сгенерированы конфиги:"
    echo "  - $clients_dir/${name}-split.conf"
    echo "  - $clients_dir/${name}-full.conf"
    echo "Используйте их для подключения на устройствах клиента."
}

# Удаление клиента
remove_client() {
    local name="$1"
    local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
    local clients_dir="${CLIENTS_DIR:-/etc/wireguard/clients}"

    log_message "INFO" "Удаление клиента: $name"

    # Проверка существования файлов конфигов
    local split_config="$clients_dir/${name}-split.conf"
    local full_config="$clients_dir/${name}-full.conf"
    if [[ ! -f "$split_config" ]] && [[ ! -f "$full_config" ]]; then
        log_message "ERROR" "Клиент $name не найден (файлы конфигов отсутствуют)."
        return 1
    fi

    # Подтверждение
    echo "Будут удалены следующие файлы:"
    [[ -f "$split_config" ]] && echo "  - $split_config"
    [[ -f "$full_config" ]] && echo "  - $full_config"
    echo "А также запись о клиенте из $wg_config_path."
    read -p "Продолжить удаление? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_message "INFO" "Удаление клиента $name отменено пользователем."
        return 0
    fi

    # Удаление файлов конфигов
    rm -f "$split_config" "$full_config"
    log_message "INFO" "Файлы конфигов клиента $name удалены."

    # Удаление секции [Peer] из wg0.conf
    # Используем sed для удаления блока, начинающегося с # Peer: <name> и заканчивающегося следующим [Peer] или концом файла
    # Это хрупкий способ, но для нашего формата комментария и структуры подходит.
    # Бэкапим оригинальный файл на всякий случай.
    cp "$wg_config_path" "$wg_config_path.bak"
    if [[ $? -ne 0 ]]; then
        log_message "WARNING" "Не удалось создать бэкап $wg_config_path перед редактированием."
    fi

    # Удаляем комментарий и следующие за ним строки до следующего [Peer] или конца файла
    sed -i "/# Peer: $name/,/^\[Peer\]/{ /# Peer: $name/!{ /^\[Peer\]/!d; }; /# Peer: $name/p; /^\[Peer\]/d; }" "$wg_config_path"

    # Также удаляем пустые строки после удаления
    sed -i '/^$/N;/^\n$/D' "$wg_config_path"

    # Применение изменений к работающему интерфейсу
    wg syncconf wg0 <(wg-quick strip wg0)
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "Ошибка при применении изменений к интерфейсу wg0 после удаления клиента. Проверьте конфигурацию и бэкап $wg_config_path.bak."
        return 1
    fi

    log_message "INFO" "Клиент $name успешно удален."
    echo "Клиент $name удален успешно."
}

# Показать список клиентов
list_clients() {
    local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
    local clients_dir="${CLIENTS_DIR:-/etc/wireguard/clients}"

    log_message "INFO" "Получение списка клиентов из $wg_config_path и $clients_dir"

    # Извлекаем имена клиентов из комментариев в wg0.conf
    local client_names_in_config
    client_names_in_config=$(grep -oP '^# Peer: \K[a-zA-Z0-9_-]+' "$wg_config_path" 2>/dev/null)

    # Извлекаем имена из файлов конфигов в clients_dir
    local client_names_in_files
    client_names_in_files=$(find "$clients_dir" -maxdepth 1 -name "*-split.conf" -o -name "*-full.conf" 2>/dev/null | \
        sed 's|.*/||' | sed 's/\(-split\|-full\)\.conf$//' | sort -u)

    # Объединяем списки и сортируем
    local all_client_names
    all_client_names=$(printf "%s\n%s" "$client_names_in_config" "$client_names_in_files" | sort -u)

    if [[ -z "$all_client_names" ]]; then
        echo "Клиенты не найдены."
        return 0
    fi

    echo "Список клиентов:"
    printf "%-20s %-15s\n" "Имя" "IP (из wg0.conf)"
    echo "----------------------------------------"
    for client_name in $all_client_names; do
        # Пытаемся найти IP этого клиента в wg0.conf
        # Ищем блок [Peer], следующий за # Peer: <name>, и извлекаем AllowedIPs
        local client_ip
        # Этот sed немного сложнее: находит # Peer: <name>, затем ищет следующий блок [Peer] или конец файла,
        # и в этом диапазоне ищет строку AllowedIPs, извлекая IP/32
        client_ip=$(sed -n "/# Peer: $client_name/,/^# Peer:/p" "$wg_config_path" | \
            grep -oP 'AllowedIPs\s*=\s*\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32' | \
            head -n 1 | \
            sed 's|/32||')
        printf "%-20s %-15s\n" "$client_name" "${client_ip:-<не найден в wg0.conf>}"
    done
}

# --- Основное меню управления клиентами ---
client_management_menu() {
    while true; do
        echo
        echo "=== Управление клиентами ==="
        echo "1. Добавить клиента"
        echo "2. Удалить клиента"
        echo "3. Показать список клиентов"
        echo "4. Вернуться в главное меню"
        echo "============================="
        read -p "Выберите действие (1-4): " choice
        case $choice in
            1)
                log_message "INFO" "Выбран пункт меню: Добавить клиента"
                read -p "Введите имя клиента (латиница, без пробелов): " client_name
                if [[ -n "$client_name" ]]; then
                    add_client "$client_name"
                else
                    echo "Имя клиента не может быть пустым."
                fi
                ;;
            2)
                log_message "INFO" "Выбран пункт меню: Удалить клиента"
                read -p "Введите имя клиента для удаления: " client_name
                if [[ -n "$client_name" ]]; then
                    remove_client "$client_name"
                else
                    echo "Имя клиента не может быть пустым."
                fi
                ;;
            3)
                log_message "INFO" "Выбран пункт меню: Показать список клиентов"
                list_clients
                ;;
            4)
                log_message "INFO" "Возврат в главное меню из управления клиентами"
                return 0
                ;;
            *)
                echo "Неверный выбор. Пожалуйста, введите число от 1 до 4."
                ;;
        esac
    done
}
