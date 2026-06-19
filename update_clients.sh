#!/bin/bash

# ==============================================================================
# Скрипт для добавления новых клиентов в существующую конфигурацию VLESS + Reality
# Автоматически считывает ключи, IP и дописывает пользователей в /usr/local/etc/xray/
# ==============================================================================

set -e

# Цвета для вывода информации в терминал
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0;m'

XRAY_PATH="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
SERVER_CONFIG_PATH="${XRAY_DIR}/config.json"
CLIENTS_DIR="${XRAY_DIR}/clients"
USER_0_PATH="${CLIENTS_DIR}/User_0.txt"

echo -e "${BLUE}=== Добавление новых клиентов VLESS (Кастомные Имена) ===${NC}"

# Проверки окружения и наличия файлов
if [ ! -f "$SERVER_CONFIG_PATH" ]; then
    echo -e "${RED}Ошибка: Действующий config.json сервера не найден по пути $SERVER_CONFIG_PATH${NC}"
    exit 1
fi

if [ ! -f "$XRAY_PATH" ]; then
    echo -e "${RED}Ошибка: Бинарный файл Xray не найден по пути $XRAY_PATH${NC}"
    exit 1
fi

if [ ! -f "$USER_0_PATH" ]; then
    echo -e "${RED}Ошибка: Технический маркер $USER_0_PATH не найден.${NC}"
    exit 1
fi

# 1. Автоматический парсинг настроек сервера
echo -e "${BLUE}Парсинг текущей конфигурации...${NC}"

SHORT_ID=$(sudo jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$SERVER_CONFIG_PATH" | tr -d '[:space:]')
DEST_FULL=$(sudo jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$SERVER_CONFIG_PATH")
DEST_DOMAIN=$(echo "$DEST_FULL" | cut -d ':' -f1 | tr -d '[:space:]')

# Извлекаем ЧИСТЫЙ Public Key из технического маркера User_0.txt
PUB_KEY=$(sudo grep "RAW_PUB_KEY:" "$USER_0_PATH" | cut -d ':' -f2 | tr -d '[:space:]\r\n')

# Сверхнадежный парсинг IP из ссылки в User_0.txt
SERVER_IP=$(sudo head -n 1 "$USER_0_PATH" | grep -oP '@\K.*(?=:\d+)' | tr -d '[:space:]')

if [ -z "$PUB_KEY" ] || [ -z "$SERVER_IP" ]; then
    echo -e "${RED}Критическая ошибка: Не удалось считать ключи или IP из файла эталона User_0.txt${NC}"
    exit 1
fi

echo -e "Обнаружен IP-адрес сервера: ${GREEN}$SERVER_IP${NC}"

ENCODED_PUB_KEY=$(echo -n "$PUB_KEY" | jq -Rr @uri | tr -d '[:space:]\r\n')

# Считаем текущих пользователей, прописанных в inbound сервера
CURRENT_USER_COUNT=$(sudo jq '.inbounds[0].settings.clients | length' "$SERVER_CONFIG_PATH")
echo -e "Текущее количество пользователей на сервере: ${YELLOW}$CURRENT_USER_COUNT${NC}"

# Запрос префикса имени для новой партии клиентов
read -p "Введите имя/префикс для новых клиентов (на английском, по умолчанию User): " INPUT_NAME
CUSTOM_NAME=$(echo "$INPUT_NAME" | tr -d '[:space:]')
CUSTOM_NAME=${CUSTOM_NAME:-"User"}

# Интерактивный запрос только количества пользователей
read -p "Сколько НОВЫХ клиентов добавить?: " NEW_COUNT
if ! [[ "$NEW_COUNT" =~ ^[0-9]+$ ]] || [ "$NEW_COUNT" -le 0 ] ; then
    echo -e "${RED}Отмена: Введено неверное число клиентов.${NC}"
    exit 1
fi

# Создаем резервную копию текущего рабочего конфига перед модификациями
sudo cp "$SERVER_CONFIG_PATH" "${SERVER_CONFIG_PATH}.bak"

# Загружаем текущий рабочий JSON в оперативную память для циклической обработки
WORKING_JSON=$(sudo cat "$SERVER_CONFIG_PATH")

declare -a NEW_LINKS
declare -a NEW_NAMES

# ------------------------------------------------------------------------------
# 2. Добавление пользователей и сборка ссылок vless:// в оперативной памяти
# ------------------------------------------------------------------------------
for ((i=1; i<=NEW_COUNT; i++)); do
    # Порядковый номер продолжает общую сквозную нумерацию для уникальности на сервере
    USER_INDEX=$((CURRENT_USER_COUNT + i))
    USER_NAME="${CUSTOM_NAME}_${USER_INDEX}"
    USER_UUID=$($XRAY_PATH uuid)
    
    echo -e "Генерация: ${YELLOW}$USER_NAME${NC} (UUID: $USER_UUID)"
    
    # Формируем структуру нового клиента для JSON сервера
    CLIENT_NODE=$(jq -n --arg id "$USER_UUID" --arg email "$USER_NAME" '{id: $id, level: 0, email: $email}')
    
    # Дописываем клиента в JSON структуру, находящуюся в памяти Bash
    WORKING_JSON=$(echo "$WORKING_JSON" | jq --argjson new_client "$CLIENT_NODE" '.inbounds[0].settings.clients += [$new_client]')
    
    # Собираем строку vless:// с новым кастомным именем профиля
    VLESS_LINK="vless://${USER_UUID}@${SERVER_IP}:443?security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${ENCODED_PUB_KEY}&sid=${SHORT_ID}&type=tcp#${USER_NAME}"
    
    # Сохраняем текстовый файл напрямую в системную папку клиентов
    echo "$VLESS_LINK" | sudo tee "$CLIENTS_DIR/${USER_NAME}.txt" > /dev/null
    
    NEW_LINKS[$i]=$VLESS_LINK
    NEW_NAMES[$i]=$USER_NAME
done

# Валидация перед записью на диск
if [ -z "$WORKING_JSON" ] || [ "$WORKING_JSON" == "null" ]; then
    echo -e "${RED}Критическая ошибка: Модификация JSON в памяти сорвалась. Отмена записи!${NC}"
    exit 1
fi

# Записываем готовый JSON на диск
echo "$WORKING_JSON" | jq . | sudo tee "$SERVER_CONFIG_PATH" > /dev/null

# ------------------------------------------------------------------------------
# 3. Перезапуск службы Xray и проверка её работоспособности
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}Перезапуск службы xray.service для применения изменений...${NC}"
sudo systemctl restart xray.service

if sudo systemctl is-active --quiet xray.service; then
    echo -e "${GREEN}=== Успешно обновлено! ===${NC}"
    echo -e "Новые файлы конфигураций сохранены в папку: ${BLUE}$CLIENTS_DIR/${NC}\n"
    
    echo -e "${YELLOW}--- Готовые ссылки vless:// для новых клиентов: ---${NC}"
    for ((i=1; i<=NEW_COUNT; i++)); do
        echo -e "${BLUE}${NEW_NAMES[$i]}:${NC}"
        echo -e "${GREEN}${NEW_LINKS[$i]}${NC}"
        echo -e "----------------------------------------"
    done
else
    echo -e "${RED}Ошибка: Xray упал. Восстанавливаем бэкап...${NC}"
    sudo cp "${SERVER_CONFIG_PATH}.bak" "$SERVER_CONFIG_PATH"
    sudo systemctl restart xray.service
    exit 1
fi