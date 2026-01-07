#!/bin/bash

# --- Вспомогательные функции ---

# Функция логирования
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Путь к лог-файлу берется из config.env, если он загружен, иначе используем путь по умолчанию
    local log_file_path="${LOG_FILE:-/etc/wireguard/logs/setup.log}"

    # Создаем директорию для лога, если не существует
    local log_dir=$(dirname "$log_file_path")
    mkdir -p "$log_dir"

    # Записываем сообщение в лог
    echo "[$timestamp] [$level] $message" >> "$log_file_path"
    # Также выводим в stdout
    echo "[$level] $message"
}

# Функция проверки формата IP-адреса
validate_ip() {
    local ip="$1"
    local regex='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    if [[ $ip =~ $regex ]]; then
        local IFS='.'
        read -ra parts <<< "$ip"
        for part in "${parts[@]}"; do
            if (( 10#$part < 0 || 10#$part > 255 )); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# Функция проверки формата CIDR
validate_cidr() {
    local cidr="$1"
    local regex='^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]|[1-2][0-9]|3[0-2])$'
    if [[ $cidr =~ $regex ]]; then
        local ip="${BASH_REMATCH[1]}"
        validate_ip "$ip"
        return $?
    else
        return 1
    fi
}

# Функция определения публичного интерфейса (выводит ТОЛЬКО имя интерфейса или пустую строку)
get_public_interface() {
    # Пытаемся определить интерфейс, используемый для маршрута по умолчанию
    local interface=$(ip route show default | awk '/default/ {print $5; exit}')
    if [[ -n "$interface" ]]; then
        # Не выводим лог здесь, только имя интерфейса
        echo "$interface"
    else
        # Не выводим лог здесь, только пустую строку
        echo ""
    fi
}

# Функция поиска следующего свободного IP для клиента
get_next_client_ip() {
    local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
    local wg_net="${WG_NET:-10.99.0.0/24}"
    local start_ip="${CLIENT_NET_START:-10.99.0.2}"
    local end_ip="${CLIENT_NET_END:-10.99.0.254}"

    # Извлекаем занятые IP из wg0.conf
    local occupied_ips=()
    if [[ -f "$wg_config_path" ]]; then
        # Ищем строки AllowedIPs, содержащие IP из нашей сети, и извлекаем IP клиента (например, x.x.x.y/32)
        occupied_ips+=($(grep -oE "AllowedIPs\s*=\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32" "$wg_config_path" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | sort -V))
    fi

    # Преобразуем start_ip и end_ip в числовые значения для сравнения
    local start_num=$(printf "%d" 0x$(printf "%02x%02x%02x%02x" $(echo "$start_ip" | tr '.' ' ')))
    local end_num=$(printf "%d" 0x$(printf "%02x%02x%02x%02x" $(echo "$end_ip" | tr '.' ' ')))

    local current_num=$start_num
    while [[ $current_num -le $end_num ]]; do
        local candidate_ip=$(printf "%d.%d.%d.%d" $(( (current_num >> 24) & 0xFF )) $(( (current_num >> 16) & 0xFF )) $(( (current_num >> 8) & 0xFF )) $(( current_num & 0xFF )))

        # Проверяем, занят ли IP
        local is_occupied=false
        for ip in "${occupied_ips[@]}"; do
            if [[ "$ip" == "$candidate_ip" ]]; then
                is_occupied=true
                break
            fi
        done

        if [[ "$is_occupied" == false ]]; then
            # log_message "INFO" "Найден свободный IP для клиента: $candidate_ip" # Логирование не в функции
            echo "$candidate_ip"
            return 0
        fi

        current_num=$((current_num + 1))
    done

    # log_message "ERROR" "Не найдено свободных IP-адресов в пуле $start_ip - $end_ip" # Логирование не в функции
    return 1
}
