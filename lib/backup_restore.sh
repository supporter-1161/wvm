#!/bin/bash

# --- Функции бэкапа и восстановления ---

# --- Внутренние вспомогательные функции для backup_restore.sh ---

# --- Основные функции ---

# Создание бэкапа
create_backup() {
    local backup_dir="${BACKUP_DIR:-/etc/wireguard/backup}"
    local wg_dir="/etc/wireguard"
    local wg_config_file="${WG_CONFIG_FILE:-$wg_dir/wg0.conf}"
    local config_env_file="${CONFIG_FILE:-$wg_dir/config.env}"
    local clients_dir="${CLIENTS_DIR:-$wg_dir/clients}"
    local private_key_file="${WG_PRIVATE_KEY_FILE:-$wg_dir/private.key}"
    local public_key_file="${WG_PUBLIC_KEY_FILE:-$wg_dir/public.key}"

    log_message "INFO" "Начало создания резервной копии в $backup_dir"

    # Создаем директорию бэкапа, если не существует
    mkdir -p "$backup_dir"

    # Генерируем имя папки бэкапа с timestamp
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_path="$backup_dir/$timestamp"

    # Создаем папку бэкапа
    mkdir -p "$backup_path"

    log_message "INFO" "Создание бэкапа в папку: $backup_path"

    # Копируем файлы
    # 1. Конфиг wg0.conf
    if [[ -f "$wg_config_file" ]]; then
        cp "$wg_config_file" "$backup_path/"
        log_message "INFO" "Скопирован wg0.conf"
    else
        log_message "WARNING" "Файл $wg_config_file не найден для бэкапа."
    fi

    # 2. Файл конфигурации скрипта config.env
    if [[ -f "$config_env_file" ]]; then
        cp "$config_env_file" "$backup_path/"
        log_message "INFO" "Скопирован config.env"
    else
        log_message "WARNING" "Файл $config_env_file не найден для бэкапа."
    fi

    # 3. Клиентские конфиги
    if [[ -d "$clients_dir" ]]; then
        cp -r "$clients_dir" "$backup_path/"
        log_message "INFO" "Скопирована папка clients"
    else
        log_message "WARNING" "Папка $clients_dir не найдена или пуста для бэкапа."
        # Создаем пустую папку в архиве, чтобы восстановление не ломалось
        mkdir -p "$backup_path/clients"
    fi

    # 4. Ключи сервера (опционально, но полезно для восстановления)
    # ВАЖНО: Эти файлы содержат приватный ключ. Храните бэкапы в безопасности!
    if [[ -f "$private_key_file" ]] && [[ -f "$public_key_file" ]]; then
        # Создаем подпапку для ключей в бэкапе для ясности
        local keys_backup_dir="$backup_path/server_keys"
        mkdir -p "$keys_backup_dir"
        cp "$private_key_file" "$keys_backup_dir/"
        cp "$public_key_file" "$keys_backup_dir/"
        log_message "INFO" "Скопированы серверные ключи в $keys_backup_dir"
        log_message "WARNING" "Бэкап содержит приватный ключ сервера. Храните его в безопасности!"
    else
        log_message "WARNING" "Серверные ключи не найдены для бэкапа (private.key, public.key)."
    fi

    # Создаем символическую ссылку 'latest' на текущий бэкап
    ln -sfn "$timestamp" "$backup_dir/latest"

    log_message "INFO" "Резервная копия успешно создана: $backup_path"
    echo "Бэкап создан в: $backup_path"
    echo "Создана ссылка 'latest' на: $backup_dir/latest"
}

# Восстановление из бэкапа
restore_from_backup() {
    local backup_dir="${BACKUP_DIR:-/etc/wireguard/backup}"
    local wg_dir="/etc/wireguard"
    local wg_config_file="${WG_CONFIG_FILE:-$wg_dir/wg0.conf}"
    local config_env_file="${CONFIG_FILE:-$wg_dir/config.env}"
    local clients_dir="${CLIENTS_DIR:-$wg_dir/clients}"
    local private_key_file="${WG_PRIVATE_KEY_FILE:-$wg_dir/private.key}"
    local public_key_file="${WG_PUBLIC_KEY_FILE:-$wg_dir/public.key}"

    log_message "INFO" "Начало процедуры восстановления из бэкапа"

    # Запрашиваем путь к архиву бэкапа
    read -p "Введите полный путь к папке бэкапа (например, $backup_dir/2024-01-01_12-00-00 или $backup_dir/latest): " backup_archive_path

    # Проверяем, существует ли папка архива
    if [[ ! -d "$backup_archive_path" ]]; then
        log_message "ERROR" "Папка бэкапа не найдена: $backup_archive_path"
        return 1
    fi

    # Проверяем наличие ключевых файлов в архиве
    local required_files=("$backup_archive_path/wg0.conf" "$backup_archive_path/config.env")
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_message "ERROR" "Отсутствует необходимый файл в архиве: $file"
            return 1
        fi
    done

    # Подтверждение восстановления (потенциально разрушительная операция)
    echo "ВНИМАНИЕ: Процедура восстановления заменит следующие файлы/папки на VPS:"
    echo "  - $wg_config_file"
    echo "  - $config_env_file"
    echo "  - $clients_dir (полностью)"
    echo "  - (опционально) $private_key_file, $public_key_file"
    echo "Текущие файлы будут ПЕРЕЗАПИСАНЫ."
    read -p "Продолжить восстановление? Это может прервать текущие VPN-соединения. (y/N): " confirm_restore
    if [[ ! $confirm_restore =~ ^[Yy]$ ]]; then
        log_message "INFO" "Восстановление отменено пользователем."
        return 0
    fi

    # Запрашиваем НОВЫЙ публичный IP VPS
    read -p "Введите НОВЫЙ публичный IP-адрес VPS: " new_server_public_ip
    if ! validate_ip "$new_server_public_ip"; then
        log_message "ERROR" "Неверный формат нового публичного IP: $new_server_public_ip"
        return 1
    fi
    log_message "INFO" "Будет использован новый IP VPS для обновления конфигов: $new_server_public_ip"

    # Останавливаем интерфейс wg0 перед восстановлением
    log_message "INFO" "Остановка интерфейса wg0 перед восстановлением..."
    wg-quick down wg0 2>/dev/null || log_message "INFO" "Интерфейс wg0 не был активен или не удалось остановить (это нормально)."

    # Копируем файлы из архива
    log_message "INFO" "Копирование файлов из архива $backup_archive_path..."

    # 1. Копируем wg0.conf
    cp "$backup_archive_path/wg0.conf" "$wg_config_file"
    log_message "INFO" "Скопирован wg0.conf"

    # 2. Копируем config.env (временно, для получения старого IP)
    local temp_config_env="$backup_archive_path/config.env"
    cp "$temp_config_env" "$config_env_file"
    log_message "INFO" "Скопирован config.env (временно)"

    # Загружаем временный config.env, чтобы получить SERVER_PUBLIC_IP ДО замены
    source "$config_env_file"
    local old_server_public_ip="$SERVER_PUBLIC_IP"
    log_message "INFO" "Обнаружен старый IP VPS в config.env: $old_server_public_ip"

    # 3. Копируем папку clients
    if [[ -d "$backup_archive_path/clients" ]]; then
        rm -rf "$clients_dir" # Удаляем старую папку
        cp -r "$backup_archive_path/clients" "$clients_dir"
        log_message "INFO" "Скопирована папка clients"
    else
        log_message "WARNING" "Папка clients не найдена в архиве. Создание пустой папки."
        mkdir -p "$clients_dir"
    fi

    # 4. Копируем ключи сервера (если есть в архиве)
    if [[ -f "$backup_archive_path/server_keys/private.key" ]] && [[ -f "$backup_archive_path/server_keys/public.key" ]]; then
        log_message "INFO" "Обнаружены серверные ключи в архиве. Копирование..."
        cp "$backup_archive_path/server_keys/private.key" "$private_key_file"
        cp "$backup_archive_path/server_keys/public.key" "$public_key_file"
        chmod 600 "$private_key_file" "$public_key_file"
        log_message "INFO" "Серверные ключи восстановлены и права установлены."
    else
        log_message "WARNING" "Серверные ключи не найдены в архиве. Возможно, потребуется перенастройка."
        # Если ключи не восстановлены, но они нужны, скрипт может завершиться ошибкой или предложить сгенерировать новые.
        # Для простоты пока просто предупреждаем.
        read -p "Ключи не восстановлены. Продолжить? (y/N): " confirm_no_keys
        if [[ ! $confirm_no_keys =~ ^[Yy]$ ]]; then
            log_message "INFO" "Восстановление отменено пользователем из-за отсутствия ключей."
            return 1
        fi
    fi

    # Обновляем IP в config.env
    log_message "INFO" "Обновление SERVER_PUBLIC_IP в $config_env_file с $old_server_public_ip на $new_server_public_ip"
    sed -i "s/^SERVER_PUBLIC_IP=.*/SERVER_PUBLIC_IP=\"$new_server_public_ip\"/" "$config_env_file"

    # Обновляем IP в клиентских конфигах
    log_message "INFO" "Обновление Endpoint в клиентских конфигах с $old_server_public_ip на $new_server_public_ip"
    find "$clients_dir" -type f -name "*.conf" -exec sed -i "s/Endpoint = $old_server_public_ip:/Endpoint = $new_server_public_ip:/" {} \;

    # Запускаем интерфейс wg0 после восстановления
    log_message "INFO" "Запуск интерфейса wg0 после восстановления..."
    wg-quick up wg0
    if [[ $? -ne 0 ]]; then
        log_message "ERROR" "Ошибка при запуске интерфейса wg0 после восстановления. Проверьте конфигурацию."
        return 1
    fi

    log_message "INFO" "Восстановление из бэкапа успешно завершено."
    echo
    echo "Восстановление завершено!"
    echo "- Конфигурация WireGuard обновлена."
    echo "- Используется новый IP VPS: $new_server_public_ip"
    echo "- Клиентские конфиги обновлены с новым IP VPS."
    echo "- Интерфейс wg0 запущен."
    echo "Раздайте обновленные клиентские конфиги пользователям."
    echo
}

# --- Основные функции обертки для вызова из главного скрипта ---
create_backup_main() {
    log_message "INFO" "Вызов процедуры создания бэкапа"
    create_backup
}

restore_from_backup_main() {
    log_message "INFO" "Вызов процедуры восстановления из бэкапа"
    restore_from_backup
}

