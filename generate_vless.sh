#!/bin/bash

# ==============================================================================
# Генератор VLESS Reality (Финальная Проверенная Версия)
# Полностью зачищает старые данные и создает чистую конфигурацию без багов.
# ==============================================================================

set -e

# Цвета для вывода в терминал
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0;m'

XRAY_PATH="/usr/local/bin/xray"
XRAY_DIR="/usr/local/etc/xray"
SERVER_CONFIG_PATH="${XRAY_DIR}/config.json"
CLIENTS_DIR="${XRAY_DIR}/clients"

# Проверки окружения
if [ ! -f "$XRAY_PATH" ]; then
    echo -e "${RED}Ошибка: Бинарный файл Xray не найден в $XRAY_PATH${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Утилита jq не найдена. Установка...${NC}"
    sudo apt-get update -y && sudo apt-get install -y jq
fi

# ------------------------------------------------------------------------------
# Полная и безопасная зачистка старых данных перед генерацией
# ------------------------------------------------------------------------------
echo -e "${BLUE}Зачистка старых конфигураций клиентов...${NC}"
sudo mkdir -p "$XRAY_DIR"
if [ -d "$CLIENTS_DIR" ]; then
    sudo rm -rf "$CLIENTS_DIR"
fi
sudo mkdir -p "$CLIENTS_DIR"
sudo chmod 755 "$CLIENTS_DIR"

# Интерактивный ввод данных
read -p "Внешний IP-адрес сервера (VPS): " SERVER_IP
if [[ -z "$SERVER_IP" ]]; then
    echo -e "${RED}Ошибка: IP-адрес сервера не может быть пустым.${NC}"
    exit 1
fi

read -p "Домен для маскировки [dl.google.com]: " DEST_DOMAIN
DEST_DOMAIN=${DEST_DOMAIN:-"dl.google.com"}

read -p "Префикс имен клиентов [User]: " INPUT_NAME
CUSTOM_NAME=$(echo "$INPUT_NAME" | tr -d '[:space:]')
CUSTOM_NAME=${CUSTOM_NAME:-"User"}

read -p "Количество клиентов для генерации [1]: " INPUT_COUNT
if ! [[ "$INPUT_COUNT" =~ ^[0-9]+$ ]] ; then
    CLIENT_COUNT=1
  else
    CLIENT_COUNT=$INPUT_COUNT
fi

# Генерация криптографических ключей Reality
echo -e "${BLUE}Генерация ключей Reality...${NC}"
X25519_OUTPUT=$($XRAY_PATH x25519)
PRIV_KEY=$(echo "$X25519_OUTPUT" | grep "Private key" | cut -d ':' -f2- | tr -d '[:space:]\r\n')
PUB_KEY=$(echo "$X25519_OUTPUT" | grep "Public key" | cut -d ':' -f2- | tr -d '[:space:]\r\n')

if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" ]]; then
    echo -e "${RED}Критическая ошибка: Не удалось извлечь ключи X25519!${NC}"
    exit 1
fi

SHORT_ID=$($XRAY_PATH uuid | tr -d '-' | head -c 16)
# [ИСПРАВЛЕНО] Надежное экранирование без лишних переносов строк в URL
ENCODED_PUB_KEY=$(echo -n "$PUB_KEY" | jq -Rr @uri | tr -d '[:space:]\r\n')

# ------------------------------------------------------------------------------
# 1. Создание изолированного технического шаблона User_0
# ------------------------------------------------------------------------------
USER_0_UUID=$($XRAY_PATH uuid)
USER_0_LINK="vless://${USER_0_UUID}@${SERVER_IP}:443?security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${ENCODED_PUB_KEY}&sid=${SHORT_ID}&type=tcp#User_0"
echo "$USER_0_LINK" | sudo tee "$CLIENTS_DIR/User_0.txt" > /dev/null
echo "# RAW_PUB_KEY:${PUB_KEY}" | sudo tee -a "$CLIENTS_DIR/User_0.txt" > /dev/null

# ------------------------------------------------------------------------------
# 2. Создание JSON и генерация файлов клиентов
# ------------------------------------------------------------------------------
echo -e "${BLUE}Формирование базы клиентов...${NC}"
CLIENTS_JSON_ARRAY=$(jq -n '[]')
declare -a VLESS_LINKS
declare -a VLESS_NAMES

for ((i=1; i<=CLIENT_COUNT; i++)); do
    UUID=$($XRAY_PATH uuid)
    NAME="${CUSTOM_NAME}_$i"
    
    # Сборка ноды для конфига сервера
    CLIENT_NODE=$(jq -n --arg id "$UUID" --arg email "$NAME" '{id: $id, level: 0, email: $email}')
    CLIENTS_JSON_ARRAY=$(echo "$CLIENTS_JSON_ARRAY" | jq ". += [$CLIENT_NODE]")
    
    # Генерация ссылки и запись в файл
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:443?security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${ENCODED_PUB_KEY}&sid=${SHORT_ID}&type=tcp#${NAME}"
    echo "$VLESS_LINK" | sudo tee "$CLIENTS_DIR/${NAME}.txt" > /dev/null
    
    VLESS_LINKS[$i]=$VLESS_LINK
    VLESS_NAMES[$i]=$NAME
done

# ------------------------------------------------------------------------------
# 3. Сборка и полная перезапись config.json
# ------------------------------------------------------------------------------
echo -e "${BLUE}Запись конфигурации config.json на диск...${NC}"
SERVER_CONFIG=$(jq -n \
    --argjson clients "$CLIENTS_JSON_ARRAY" \
    --arg dest "$DEST_DOMAIN:443" \
    --arg serverName "$DEST_DOMAIN" \
    --arg privKey "$PRIV_KEY" \
    --arg shortId "$SHORT_ID" \
    '{
        log: {loglevel: "warning"},
        inbounds: [{
            port: 443,
            protocol: "vless",
            settings: {clients: $clients, decryption: "none"},
            streamSettings: {
                network: "tcp",
                security: "reality",
                realitySettings: {
                    show: false,
                    dest: $dest,
                    xver: 0,
                    serverNames: [$serverName],
                    privateKey: $privKey,
                    shortIds: [$shortId]
                }
            }
        }],
        outbounds: [
            {protocol: "freedom", settings: {}, tag: "direct"},
            {protocol: "blackhole", settings: {}, tag: "block"}
        ]
    }')

echo "$SERVER_CONFIG" | jq . | sudo tee "$SERVER_CONFIG_PATH" > /dev/null

# ------------------------------------------------------------------------------
# 4. Перезапуск службы Xray и вывод результатов
# ------------------------------------------------------------------------------
echo -e "${BLUE}Перезапуск службы xray.service...${NC}"
sudo systemctl restart xray.service

if sudo systemctl is-active --quiet xray.service; then
    echo -e "${GREEN}=== Сервер успешно настроен! ===${NC}"
    echo -e "Предыдущие сессии стерты. Актуальный шаблон User_0 сохранен.\n"
    echo -e "${YELLOW}--- Готовые ссылки vless:// для подключения: ---${NC}"
    for ((i=1; i<=CLIENT_COUNT; i++)); do
        echo -e "${BLUE}${VLESS_NAMES[$i]}:${NC}"
        echo -e "${GREEN}${VLESS_LINKS[$i]}${NC}"
        echo -e "----------------------------------------"
    done
else
    echo -e "${RED}Ошибка: Демон Xray не смог запуститься с новым конфигом.${NC}"
    exit 1
fi