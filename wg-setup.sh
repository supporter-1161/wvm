#!/bin/bash

# Проверка root прав
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен с правами root (sudo)." 1>&2
   exit 1
fi

# Определение директории скрипта и зависимых папок
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LIB_DIR="$SCRIPT_DIR/lib"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

# Подключение библиотечных файлов
source "$LIB_DIR/functions.sh" || { echo "Ошибка: Не удалось подключить functions.sh"; exit 1; }
source "$LIB_DIR/setup.sh" || { echo "Ошибка: Не удалось подключить setup.sh"; exit 1; }
source "$LIB_DIR/client_management.sh" || { echo "Ошибка: Не удалось подключить client_management.sh"; exit 1; }
source "$LIB_DIR/backup_restore.sh" || { echo "Ошибка: Не удалось подключить backup_restore.sh"; exit 1; }
source "$LIB_DIR/monitoring.sh" || { echo "Ошибка: Не удалось подключить monitoring.sh"; exit 1; }
# Подключаем новый файл
source "$LIB_DIR/gateway_config.sh" || { echo "Ошибка: Не удалось подключить gateway_config.sh"; exit 1; }

# Путь к файлу конфигурации на VPS
CONFIG_FILE="/etc/wireguard/config.env"

# Загрузка конфигурации, если файл существует
if [[ -f "$CONFIG_FILE" ]]; then
    log_message "INFO" "Загрузка конфигурации из $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    log_message "WARNING" "Файл конфигурации $CONFIG_FILE не найден. Предполагается первоначальная настройка."
    # Установка значений по умолчанию для проверки существования переменных
    SETUP_COMPLETED="${SETUP_COMPLETED:-false}"
fi

# --- Функция главного меню ---
main_menu() {
    while true; do
        echo
        echo "=== WireGuard VPN Manager (WVM) ==="
        echo "1. Первоначальная настройка"
        echo "2. Управление клиентами"
        echo "3. Настройка домашнего шлюза"
        echo "4. Создать бэкап"
        echo "5. Восстановить из бэкапа"
        echo "6. Мониторинг"
        echo "7. Выход"
        echo "====================================="

        read -p "Выберите действие (1-7): " choice

        case $choice in
            1)
                log_message "INFO" "Выбран пункт меню: Первоначальная настройка"
                if [[ "$SETUP_COMPLETED" == "true" ]]; then
                    echo "Предупреждение: WireGuard, похоже, уже настроен (флаг SETUP_COMPLETED=true)."
                    read -p "Первоначальная настройка перезапишет текущую конфигурацию. Продолжить? (y/N): " confirm
                    if [[ $confirm =~ ^[Yy]$ ]]; then
                        initial_setup_main
                    else
                        echo "Операция отменена."
                    fi
                else
                    initial_setup_main
                fi
            ;;
            2)
                log_message "INFO" "Выбран пункт меню: Управление клиентами"
                client_management_menu
            ;;
            # Новый пункт меню
            3)
                log_message "INFO" "Выбран пункт меню: Настройка домашнего шлюза"
                configure_home_gateway_main
            ;;
            4)
                log_message "INFO" "Выбран пункт меню: Создать бэкап"
                create_backup_main
            ;;
            5)
                log_message "INFO" "Выбран пункт меню: Восстановить из бэкапа"
                restore_from_backup_main
            ;;
            6)
                log_message "INFO" "Выбран пункт меню: Мониторинг"
                monitoring_menu
            ;;
            7)
                log_message "INFO" "Выход из скрипта"
                echo "До свидания!"
                exit 0
            ;;
            *)
                echo "Неверный выбор. Пожалуйста, введите число от 1 до 7."
            ;;
        esac
    done
}

# --- Запуск главного меню ---
main_menu
