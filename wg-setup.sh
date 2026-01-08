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
                        # --- Запрашиваем параметры для initial_setup_main ---
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
                            continue
                        fi
                        log_message "INFO" "Выбран порт: $WG_PORT"

                        # Пул VPN-адресов
                        read -p "Введите пул VPN-адресов (CIDR, по умолчанию 10.99.0.0/24): " input_wg_net
                        WG_NET="${input_wg_net:-10.99.0.0/24}"
                        if ! validate_cidr "$WG_NET"; then
                            log_message "ERROR" "Неверный формат CIDR для пула: $WG_NET"
                            continue
                        fi
                        log_message "INFO" "Выбран пул: $WG_NET"

                        # IP домашнего DNS в VPN
                        read -p "Введите IP домашнего DNS-сервера в VPN (по умолчанию 10.99.0.100): " input_home_dns
                        HOME_DNS_WG_IP="${input_home_dns:-10.99.0.100}"
                        if ! validate_ip "$HOME_DNS_WG_IP"; then
                            log_message "ERROR" "Неверный формат IP для домашнего DNS: $HOME_DNS_WG_IP"
                            continue
                        fi
                        log_message "INFO" "Выбран IP домашнего DNS в VPN: $HOME_DNS_WG_IP"

                        # Диапазон домашней сети
                        read -p "Введите диапазон домашней сети (CIDR, по умолчанию 192.168.0.0/24): " input_home_net
                        HOME_NET="${input_home_net:-192.168.0.0/24}"
                        if ! validate_cidr "$HOME_NET"; then
                            log_message "ERROR" "Неверный формат CIDR для домашней сети: $HOME_NET"
                            continue
                        fi
                        log_message "INFO" "Выбран диапазон домашней сети: $HOME_NET"

                        # Публичный IP VPS
                        read -p "Введите публичный IP-адрес VPS: " input_server_public_ip
                        if ! validate_ip "$input_server_public_ip"; then
                            log_message "ERROR" "Неверный формат публичного IP: $input_server_public_ip"
                            continue
                        fi
                        SERVER_PUBLIC_IP="$input_server_public_ip"
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
                            continue
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
                            continue # Вернуться в меню
                        fi

                        # Вызов initial_setup_main с переданными переменными
                        # Передаем переменные как окружение для setup.sh
                        WG_MODE="$WG_MODE" WG_PORT="$WG_PORT" WG_NET="$WG_NET" \
                        HOME_DNS_WG_IP="$HOME_DNS_WG_IP" HOME_NET="$HOME_NET" \
                        SERVER_PUBLIC_IP="$SERVER_PUBLIC_IP" PUBLIC_INTERFACE="$PUBLIC_INTERFACE" \
                        initial_setup_main

                        # После выполнения, перезагрузим config.env
                        if [[ -f "$CONFIG_FILE" ]]; then
                            log_message "INFO" "Перезагрузка конфигурации из $CONFIG_FILE"
                            source "$CONFIG_FILE"
                        fi

                    else
                        echo "Операция отменена."
                    fi
                else
                    # --- Если SETUP_COMPLETED не true, запрашиваем параметры ---
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
                        continue
                    fi
                    log_message "INFO" "Выбран порт: $WG_PORT"

                    # Пул VPN-адресов
                    read -p "Введите пул VPN-адресов (CIDR, по умолчанию 10.99.0.0/24): " input_wg_net
                    WG_NET="${input_wg_net:-10.99.0.0/24}"
                    if ! validate_cidr "$WG_NET"; then
                        log_message "ERROR" "Неверный формат CIDR для пула: $WG_NET"
                        continue
                    fi
                    log_message "INFO" "Выбран пул: $WG_NET"

                    # IP домашнего DNS в VPN
                    read -p "Введите IP домашнего DNS-сервера в VPN (по умолчанию 10.99.0.100): " input_home_dns
                    HOME_DNS_WG_IP="${input_home_dns:-10.99.0.100}"
                    if ! validate_ip "$HOME_DNS_WG_IP"; then
                        log_message "ERROR" "Неверный формат IP для домашнего DNS: $HOME_DNS_WG_IP"
                        continue
                    fi
                    log_message "INFO" "Выбран IP домашнего DNS в VPN: $HOME_DNS_WG_IP"

                    # Диапазон домашней сети
                    read -p "Введите диапазон домашней сети (CIDR, по умолчанию 192.168.0.0/24): " input_home_net
                    HOME_NET="${input_home_net:-192.168.0.0/24}"
                    if ! validate_cidr "$HOME_NET"; then
                        log_message "ERROR" "Неверный формат CIDR для домашней сети: $HOME_NET"
                        continue
                    fi
                    log_message "INFO" "Выбран диапазон домашней сети: $HOME_NET"

                    # Публичный IP VPS
                    read -p "Введите публичный IP-адрес VPS: " input_server_public_ip
                    if ! validate_ip "$input_server_public_ip"; then
                        log_message "ERROR" "Неверный формат публичного IP: $input_server_public_ip"
                        continue
                    fi
                    SERVER_PUBLIC_IP="$input_server_public_ip"
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
                        continue
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
                        continue # Вернуться в меню
                    fi

                    # Вызов initial_setup_main с переданными переменными
                    # Передаем переменные как окружение для setup.sh
                    WG_MODE="$WG_MODE" WG_PORT="$WG_PORT" WG_NET="$WG_NET" \
                    HOME_DNS_WG_IP="$HOME_DNS_WG_IP" HOME_NET="$HOME_NET" \
                    SERVER_PUBLIC_IP="$SERVER_PUBLIC_IP" PUBLIC_INTERFACE="$PUBLIC_INTERFACE" \
                    initial_setup_main

                    # После выполнения, перезагрузим config.env
                    if [[ -f "$CONFIG_FILE" ]]; then
                        log_message "INFO" "Перезагрузка конфигурации из $CONFIG_FILE"
                        source "$CONFIG_FILE"
                    fi

                fi
            ;;
            2)
                log_message "INFO" "Выбран пункт меню: Управление клиентами"
                # Убедимся, что config.env загружен, прежде чем вызывать client_management_menu
                if [[ -f "$CONFIG_FILE" ]]; then
                    source "$CONFIG_FILE"
                fi
                client_management_menu
            ;;
            # Новый пункт меню
            3)
                log_message "INFO" "Выбран пункт меню: Настройка домашнего шлюза"
                # Убедимся, что config.env загружен
                if [[ -f "$CONFIG_FILE" ]]; then
                    source "$CONFIG_FILE"
                fi
                configure_home_gateway_main
            ;;
            4)
                log_message "INFO" "Выбран пункт меню: Создать бэкап"
                # Убедимся, что config.env загружен
                if [[ -f "$CONFIG_FILE" ]]; then
                    source "$CONFIG_FILE"
                fi
                create_backup_main
            ;;
            5)
                log_message "INFO" "Выбран пункт меню: Восстановить из бэкапа"
                # Убедимся, что config.env загружен
                if [[ -f "$CONFIG_FILE" ]]; then
                    source "$CONFIG_FILE"
                fi
                restore_from_backup_main
            ;;
            6)
                log_message "INFO" "Выбран пункт меню: Мониторинг"
                # Убедимся, что config.env загружен
                if [[ -f "$CONFIG_FILE" ]]; then
                    source "$CONFIG_FILE"
                fi
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
