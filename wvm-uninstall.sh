#!/bin/bash

# --- Скрипт для полной деинсталляции WireGuard VPN Manager (WVM) ---

# Проверка root прав
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен с правами root (sudo)." 1>&2
   exit 1
fi

# --- Функция логирования ---
log_uninstall() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Выводим в stdout
    echo "[$timestamp] [$level] $message"
}

# --- Функция подтверждения ---
confirm_action() {
    local prompt="$1"
    read -p "$prompt (y/N): " response
    if [[ ! $response =~ ^[Yy]$ ]]; then
        log_uninstall "INFO" "Деинсталляция отменена пользователем."
        exit 0
    fi
}

# --- Основная функция деинсталляции ---
uninstall_wvm() {
    log_uninstall "INFO" "Начало процедуры деинсталляции WVM."

    # --- 1. Остановка и отключение сервиса WireGuard ---
    log_uninstall "INFO" "Остановка и отключение сервиса wg-quick@wg0..."
    if systemctl is-active --quiet wg-quick@wg0; then
        systemctl stop wg-quick@wg0
        log_uninstall "INFO" "Сервис wg-quick@wg0 остановлен."
    else
        log_uninstall "INFO" "Сервис wg-quick@wg0 не был активен."
    fi

    if systemctl is-enabled --quiet wg-quick@wg0; then
        systemctl disable wg-quick@wg0
        log_uninstall "INFO" "Автозапуск wg-quick@wg0 отключен."
    else
        log_uninstall "INFO" "Автозапуск wg-quick@wg0 уже был отключен."
    fi

    # --- 2. Удаление файлов конфигурации и данных ---
    local wg_dir="/etc/wireguard"
    log_uninstall "INFO" "Удаление файлов из $wg_dir..."

    # Сохраняем список файлов, которые мы удаляем, на случай ошибки
    local files_to_remove=("$wg_dir/wg0.conf" "$wg_dir/config.env" "$wg_dir/private.key" "$wg_dir/public.key")
    local dirs_to_remove=("$wg_dir/clients" "$wg_dir/backup" "$wg_dir/logs" "$wg_dir/wg-home-gateway.conf") # Добавляем файл от WVM

    for file in "${files_to_remove[@]}"; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            log_uninstall "INFO" "Удален файл: $file"
        else
            log_uninstall "INFO" "Файл не найден для удаления: $file"
        fi
    done

    for dir in "${dirs_to_remove[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            log_uninstall "INFO" "Удалена папка: $dir"
        else
            log_uninstall "INFO" "Папка не найдена для удаления: $dir"
        fi
    done

    # --- 3. Откат изменений в sysctl (IP forwarding) ---
    log_uninstall "INFO" "Попытка отката настройки IP forwarding (/etc/sysctl.conf)..."
    local sysctl_conf="/etc/sysctl.conf"
    if [[ -f "$sysctl_conf" ]]; then
        # Удаляем строку net.ipv4.ip_forward=1
        sed -i '/^net\.ipv4\.ip_forward=1/d' "$sysctl_conf"
        log_uninstall "INFO" "Строка 'net.ipv4.ip_forward=1' удалена из $sysctl_conf (если была)."
        # Опционально: отключить IP forwarding (только временно)
        # sysctl -w net.ipv4.ip_forward=0
        # log_uninstall "INFO" "IP forwarding отключен (временно, до перезагрузки, если не было других источников)."
    else
        log_uninstall "WARNING" "Файл $sysctl_conf не найден."
    fi


    # --- 4. Откат изменений в iptables (предполагаем, что правила добавлялись через WVM) ---
    # Это хрупко, так как правила не имеют уникальных маркеров. Мы можем попытаться удалить их по содержимому.
    log_uninstall "INFO" "Попытка отката изменений в iptables (Forward и NAT для wg0)..."
    # Удаляем правила Forward (предполагаем, что WVM добавлял их как wg-quick)
    # Это неидеальный способ, но для тестирования подойдет.
    # wg-quick добавляет правила типа: -A FORWARD -i wg0 -j ACCEPT и -A FORWARD -o wg0 -j ACCEPT
    # И NAT: -A POSTROUTING -s 10.99.0.0/24 -o eth0 -j MASQUERADE (или другой интерфейс)
    # Мы не знаем, какой был интерфейс. Попробуем удалить по маске wg0 и маскараду.
    # Удаляем правила, связанные с интерфейсом wg0 в FORWARD
    iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true
    # Удаляем любые правила MASQUERADE, содержащие wg0 в адресе источника (это грубовато, но для WVM подходит)
    # Получим все цепочки NAT и поищем MASQUERADE
    local nat_rules
    nat_rules=$(iptables-save -t nat 2>/dev/null | grep -i masquerade | grep -i wg0)
    if [[ -n "$nat_rules" ]]; then
        log_uninstall "INFO" "Найдены правила MASQUERADE для wg0. Попытка удаления..."
        # Парсим и удаляем каждое правило
        while IFS= read -r rule; do
            # Преобразуем строку из iptables-save в команду iptables -D
            # Убираем '-A' и заменяем на '-D', добавляем '-t nat'
            local delete_rule=$(echo "$rule" | sed 's/^-A/-t nat -D/')
            log_uninstall "INFO" "Удаление правила: $delete_rule"
            eval iptables $delete_rule 2>/dev/null || log_uninstall "WARNING" "Не удалось удалить правило: $delete_rule"
        done <<< "$nat_rules"
    fi
    log_uninstall "INFO" "Попытка отката iptables завершена."


    # --- 5. Откат изменений в UFW (если был настроен через WVM) ---
    log_uninstall "INFO" "Попытка отката изменений в UFW (порт WireGuard)..."
    local wg_port_from_config=""
    # Попробуем получить порт из config.env, если он существует
    if [[ -f "$wg_dir/config.env" ]]; then
        # Извлекаем значение WG_PORT из файла
        wg_port_from_config=$(grep "^WG_PORT=" "$wg_dir/config.env" | cut -d'=' -f2 | tr -d '"')
    fi

    if [[ -n "$wg_port_from_config" ]]; then
        # Пытаемся удалить правило для конкретного порта
        ufw delete allow "$wg_port_from_config"/udp 2>/dev/null && log_uninstall "INFO" "Правило UFW для порта $wg_port_from_config/udp удалено."
    else
        log_uninstall "INFO" "Порт WireGuard не найден в $wg_dir/config.env. Не удалось автоматически удалить правило UFW."
        # Альтернатива: попытаться удалить правило, которое может быть связано с wg0.conf ListenPort
        # Но это еще сложнее без парсинга wg0.conf.
        # Лучше вручную или через wg-show, если известен порт.
    fi


    # --- 6. Удаление самого скрипта деинсталляции (опционально) ---
    # read -p "Удалить этот скрипт деинсталляции (wvm-uninstall.sh)? (y/N): " confirm_rm_self
    # if [[ $confirm_rm_self =~ ^[Yy]$ ]]; then
    #     rm -- "$0" 2>/dev/null
    #     log_uninstall "INFO" "Скрипт wvm-uninstall.sh удален."
    # fi

    log_uninstall "INFO" "Процедура деинсталляции WVM завершена."
    log_uninstall "INFO" "Файлы и сервисы WireGuard, созданные WVM, удалены."
    log_uninstall "INFO" "Обратите внимание: возможны остаточные правила iptables/ufw или sysctl, установленные другими средствами."
    log_uninstall "INFO" "Рекомендуется перезагрузка для полного сброса сетевых настроек."
}

# --- Запуск ---
echo "ВНИМАНИЕ: Эта процедура полностью удалит WireGuard VPN Manager (WVM) и все связанные с ним файлы, настройки и правила."
echo "Это действие НЕЛЬЗЯ отменить!"
confirm_action "Продолжить деинсталляцию?"

uninstall_wvm

