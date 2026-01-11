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

    # Удаляем стандартные файлы
    rm -f "$wg_dir/wg0.conf" "$wg_dir/config.env" "$wg_dir/private.key" "$wg_dir/public.key"
    log_uninstall "INFO" "Удалены основные файлы: wg0.conf, config.env, ключи"

    # Удаляем ВСЕ конфиги шлюзов: wg-*.conf
    shopt -s nullglob
    local gateway_configs=("$wg_dir"/wg-*.conf)
    shopt -u nullglob
    if [[ ${#gateway_configs[@]} -gt 0 ]]; then
        for conf in "${gateway_configs[@]}"; do
            rm -f "$conf"
            log_uninstall "INFO" "Удалён конфиг шлюза: $conf"
        done
    else
        log_uninstall "INFO" "Конфиги шлюзов (wg-*.conf) не найдены."
    fi

    # Удаляем бэкапы: wg0.conf.backup_before_gateway_*
    shopt -s nullglob
    local backup_files=("$wg_dir"/wg0.conf.backup_before_gateway_*)
    shopt -u nullglob
    if [[ ${#backup_files[@]} -gt 0 ]]; then
        for bkp in "${backup_files[@]}"; do
            rm -f "$bkp"
            log_uninstall "INFO" "Удалён бэкап: $bkp"
        done
    else
        log_uninstall "INFO" "Бэкапы (wg0.conf.backup_before_gateway_*) не найдены."
    fi

    # Удаляем директории
    rm -rf "$wg_dir/clients" "$wg_dir/backup" "$wg_dir/logs"
    log_uninstall "INFO" "Удалены директории: clients, backup, logs"

    # --- 3. Откат изменений в sysctl (IP forwarding) ---
    log_uninstall "INFO" "Попытка отката настройки IP forwarding (/etc/sysctl.conf)..."
    local sysctl_conf="/etc/sysctl.conf"
    if [[ -f "$sysctl_conf" ]]; then
        sed -i '/^net\.ipv4\.ip_forward=1/d' "$sysctl_conf"
        log_uninstall "INFO" "Строка 'net.ipv4.ip_forward=1' удалена из $sysctl_conf (если была)."
    else
        log_uninstall "WARNING" "Файл $sysctl_conf не найден."
    fi

    # --- 4. Откат iptables ---
    log_uninstall "INFO" "Попытка отката изменений в iptables (Forward и NAT для wg0)..."
    iptables -D FORWARD -i wg0 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o wg0 -j ACCEPT 2>/dev/null || true

    # Удаляем MASQUERADE правила, связанные с wg0
    local nat_rules
    nat_rules=$(iptables-save -t nat 2>/dev/null | grep -i masquerade | grep -i wg0)
    if [[ -n "$nat_rules" ]]; then
        while IFS= read -r rule; do
            local delete_rule=$(echo "$rule" | sed 's/^-A/-t nat -D/')
            eval iptables $delete_rule 2>/dev/null || true
        done <<< "$nat_rules"
    fi
    log_uninstall "INFO" "Попытка отката iptables завершена."

    # --- 5. Откат UFW ---
    log_uninstall "INFO" "Попытка отката изменений в UFW (порт WireGuard)..."
    local wg_port_from_config=""
    if [[ -f "$wg_dir/config.env" ]]; then
        wg_port_from_config=$(grep "^WG_PORT=" "$wg_dir/config.env" | cut -d'=' -f2 | tr -d '"')
    fi
    if [[ -n "$wg_port_from_config" ]]; then
        ufw delete allow "$wg_port_from_config"/udp 2>/dev/null && \
            log_uninstall "INFO" "Правило UFW для порта $wg_port_from_config/udp удалено."
    else
        log_uninstall "INFO" "Порт WireGuard не найден в config.env. Пропуск удаления UFW."
    fi

    log_uninstall "INFO" "Процедура деинсталляции WVM завершена."
    log_uninstall "INFO" "Все файлы, конфиги шлюзов и бэкапы удалены."
    log_uninstall "INFO" "Рекомендуется перезагрузка для полного сброса сетевых настроек."
}

# --- Запуск ---
echo "ВНИМАНИЕ: Эта процедура полностью удалит WireGuard VPN Manager (WVM) и все связанные с ним файлы, настройки и правила."
echo "Это действие НЕЛЬЗЯ отменить!"
confirm_action "Продолжить деинсталляцию?"
uninstall_wvm
