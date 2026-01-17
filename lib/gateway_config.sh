#!/bin/bash
# --- Функции для настройки домашнего шлюза ---
# --- Внутренние вспомогательные функции для gateway_config.sh ---
# --- Основные функции ---
# Функция генерации конфига для домашнего шлюза и обновления wg0.conf на VPS
# Теперь генерирует ключи на VPS
configure_home_gateway() {
log_message "INFO" "Запуск процедуры настройки домашнего шлюза (генерация ключей на VPS)."
# Проверяем, была ли выполнена первоначальная настройка
if [[ "$SETUP_COMPLETED" != "true" ]]; then
log_message "ERROR" "Первоначальная настройка VPS не выполнена. Запустите сначала 'Первоначальная настройка'."
echo "Ошибка: Первоначальная настройка VPS не выполнена."
return 1
fi
# Загружаем переменные из config.env, если они еще не были загружены в основном скрипте
local wg_config_path="${WG_CONFIG_FILE:-/etc/wireguard/wg0.conf}"
local server_public_key_file="${WG_PUBLIC_KEY_FILE:-/etc/wireguard/public.key}"
local server_public_key
server_public_key=$(cat "$server_public_key_file")
# Запрашиваем параметры у пользователя
echo "=== Настройка домашнего шлюза (ключ генерируется на VPS) ==="
# Имя для шлюза (для удобства, будет использовано в комментарии и для файла конфига)
read -p "Введите имя для домашнего шлюза (по умолчанию home-gateway): " input_home_gw_name
local home_gw_name="${input_home_gw_name:-home-gateway}"
# WireGuard IP для шлюза
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
# Запрашиваем LAN интерфейс на шлюзе
read -p "Введите имя LAN интерфейса на домашнем шлюзе (по умолчанию eth0): " input_home_gw_lan_iface
local home_gw_lan_iface="${input_home_gw_lan_iface:-eth0}"
# Подтверждение
echo
echo "Проверьте введенные данные:"
echo "Имя шлюза: $home_gw_name"
echo "WireGuard IP шлюза: $home_gw_wg_ip"
echo "LAN IP шлюза: $home_gw_lan_ip"
echo "LAN интерфейс шлюза: $home_gw_lan_iface"
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
# --- Генерация ключей для шлюза ---
log_message "INFO" "Генерация ключей для домашнего шлюза '$home_gw_name' (IP: $home_gw_wg_ip)."
# Создаем временные файлы для ключей шлюза
local temp_dir
temp_dir=$(mktemp -d)
if [[ $? -ne 0 ]]; then
log_message "ERROR" "Не удалось создать временную папку для ключей шлюза."
return 1
fi
local gw_private_key_file="$temp_dir/gateway_private.key"
local gw_public_key_file="$temp_dir/gateway_public.key"
# Генерируем ключи
umask 077
wg genkey | tee "$gw_private_key_file" | wg pubkey > "$gw_public_key_file"
local ret=$?
umask 022
if [[ $ret -ne 0 ]]; then
log_message "ERROR" "Ошибка при генерации ключей для домашнего шлюза '$home_gw_name'."
rm -rf "$temp_dir"
return $ret
fi
local gw_private_key
local gw_public_key
gw_private_key=$(cat "$gw_private_key_file")
gw_public_key=$(cat "$gw_public_key_file")
log_message "INFO" "Ключи для домашнего шлюза '$home_gw_name' сгенерированы."
# --- Обновление wg0.conf на VPS ---
log_message "INFO" "Обновление wg0.conf ($wg_config_path) для добавления домашнего шлюза '$home_gw_name'."
# Проверяем, существует ли уже запись для этого IP (защита от дублирования)
if grep -q "# Peer: $home_gw_name" "$wg_config_path" && grep -A 10 "# Peer: $home_gw_name" "$wg_config_path" | grep -q "$home_gw_wg_ip"; then
log_message "WARNING" "Запись для домашнего шлюза '$home_gw_name' с IP $home_gw_wg_ip уже существует в wg0.conf. Обновление пропущено."
echo "Предупреждение: Запись для шлюза '$home_gw_name' с IP $home_gw_wg_ip уже существует."
rm -rf "$temp_dir"
return 0
fi
# Создаем бэкап wg0.conf перед изменением
cp "$wg_config_path" "$wg_config_path.backup_before_gateway_$(date +%s)"
log_message "INFO" "Создан бэкап wg0.conf: $(ls -la $wg_config_path.backup_before_gateway_* 2>/dev/null | tail -n 1 | awk '{print $NF}')"
# Удаляем старый комментарий (если он есть) и добавляем нового пира в конец файла
sed -i '/# HOME GATEWAY (добавить позже)/,/AllowedIPs = .*, .*/d' "$wg_config_path"
# Добавляем пира для домашнего шлюза в конец файла
# ВАЖНО: AllowedIPs для шлюза НЕ зависит от режима клиента, он всегда отвечает за WG_IP и HOME_NET
cat >> "$wg_config_path" << EOF
# Peer: $home_gw_name
[Peer]
PublicKey = $gw_public_key
AllowedIPs = $home_gw_wg_ip/32, $HOME_NET
EOF
log_message "INFO" "Добавлена запись для домашнего шлюза '$home_gw_name' в wg0.conf."
# Применение изменений к работающему интерфейсу
wg syncconf wg0 <(wg-quick strip wg0)
if [[ $? -ne 0 ]]; then
log_message "ERROR" "Ошибка при применении изменений к интерфейсу wg0. Проверьте конфигурацию и бэкап."
rm -rf "$temp_dir"
return 1
fi
log_message "INFO" "Изменения в wg0.conf применены к интерфейсу wg0."

# --- Добавляем маршрут к домашней сети через интерфейс wg0 ---
# Это позволяет VPS направлять трафик к устройствам в HOME_NET через туннель wg0,
# как только пир (домашний шлюз) будет настроен.
log_message "INFO" "Добавление маршрута к домашней сети $HOME_NET через интерфейс wg0."
ip route add $HOME_NET dev wg0 2>/dev/null || {
    local ret=$?
    log_message "WARNING" "Не удалось добавить маршрут к $HOME_NET через wg0 (код: $ret). Возможно, маршрут уже существует или интерфейс недоступен."
    # Не завершаем функцию с ошибкой, так как это не всегда критично, но логируем.
    # Если маршрут уже есть, это нормально.
    # Если интерфейс не готов, можно попробовать позже вручную.
}
# --- Конец добавления маршрута ---

# --- Генерация конфига для домашнего шлюза ---
local gateway_config_filename="wg-$home_gw_name.conf"
local gateway_config_path="/etc/wireguard/$gateway_config_filename"
log_message "INFO" "Генерация конфига для домашнего шлюза: $gateway_config_path"
# Создаем корректный конфиг: PostUp/PostDown внутри [Interface], до [Peer]

cat > "$gateway_config_path" << EOF
[Interface]
PrivateKey = $gw_private_key
Address = $home_gw_wg_ip/32
# DNS = $home_gw_lan_ip # Если хотите, чтобы шлюз использовал свой локальный DNS для запросов от VPS
# Правила для проброса трафика из VPN в домашнюю сеть
# Замените $home_gw_lan_iface на реальный LAN интерфейс шлюза (например, br0, lan0), если отличается от введенного

PostUp = iptables -A FORWARD -i %i -o $home_gw_lan_iface -j ACCEPT
PostUp = iptables -A FORWARD -i $home_gw_lan_iface -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s $WG_NET -o $home_gw_lan_iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -o $home_gw_lan_iface -j ACCEPT
PostDown = iptables -D FORWARD -i $home_gw_lan_iface -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $WG_NET -o $home_gw_lan_iface -j MASQUERADE

[Peer]
PublicKey = $server_public_key
Endpoint = $SERVER_PUBLIC_IP:$WG_PORT
# AllowedIPs = $WG_NET, $HOME_NET
AllowedIPs = $WG_NET
PersistentKeepalive = 25
EOF

chmod 600 "$gateway_config_path"
log_message "INFO" "Конфиг для домашнего шлюза '$home_gw_name' создан: $gateway_config_path"
# Удаляем временные ключи
rm -rf "$temp_dir"
# --- Инструкция пользователю ---
echo
echo "=== Настройка домашнего шлюза завершена ==="
echo "1. Скопируйте файл конфигурации на ваш домашний шлюз:"
echo "   scp $gateway_config_path user@home_gateway_ip:/tmp/"
echo "2. На домашнем шлюзе:"
echo "   a. Переместите файл в /etc/wireguard/:"
echo "      sudo mv /tmp/$gateway_config_filename /etc/wireguard/"
echo "   b. Убедитесь, что '$home_gw_lan_iface' - это правильный LAN-интерфейс на шлюзе."
echo "      Если нет, отредактируйте $gateway_config_filename и замените '$home_gw_lan_iface' на реальный."
echo "   c. Запустите интерфейс:"
echo "      sudo wg-quick up $gateway_config_filename"
echo "   d. (Опционально) Включите автозапуск:"
echo "      sudo systemctl enable wg-quick@$gateway_config_filename"
echo "3. Проверьте соединение (на VPS):"
echo "   sudo ./wg-setup.sh -> 'Мониторинг' -> 'Проверить доступ к домашней сети'"
echo "==============================================="
echo "Сгенерированный конфиг для шлюза: $gateway_config_path"
echo "Не забудьте обновить интерфейс на шлюзе!"
}
# --- Основная функция для вызова из главного скрипта ---
configure_home_gateway_main() {
log_message "INFO" "Вызов процедуры настройки домашнего шлюза (генерация ключей на VPS)"
configure_home_gateway
}
