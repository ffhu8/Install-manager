#!/bin/bash

# ==============================================================================
# Скрипт для безопасного удаления клиентов из конфигурации VLESS + Reality
# Удаляет запись из config.json сервера и уничтожает файл .txt в папке clients
# ==============================================================================

set -e

# Цвета для вывода информации в терминал
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0;m'

XRAY_DIR="/usr/local/etc/xray"
SERVER_CONFIG_PATH="${XRAY_DIR}/config.json"
CLIENTS_DIR="${XRAY_DIR}/clients"

echo -e "${BLUE}=== Удаление клиентов VLESS (Проверенная Версия) ===${NC}"

# Проверки окружения и наличия файлов
if [ ! -f "$SERVER_CONFIG_PATH" ]; then
    echo -e "${RED}Ошибка: Действующий config.json сервера не найден по пути $SERVER_CONFIG_PATH${NC}"
    exit 1
fi

# Получаем список email-адресов (имен) клиентов из config.json сервера, исключая User_0
RAW_CLIENTS=$(sudo jq -r '.inbounds[0].settings.clients[].email' "$SERVER_CONFIG_PATH" | grep -v 'User_0' || true)

# Очищаем от возможных пустых строк
RAW_CLIENTS=$(echo "$RAW_CLIENTS" | sed '/^$/d')

# Читаем список в массив Bash
if [ -z "$RAW_CLIENTS" ]; then
    echo -e "${YELLOW}На сервере нет активных пользователей для удаления (кроме системного User_0).${NC}"
    exit 0
fi

mapfile -t CLIENT_LIST <<< "$RAW_CLIENTS"

# Выводим список пользователей для выбора
echo -e "${YELLOW}Доступные для удаления пользователи:${NC}"
for i in "${!CLIENT_LIST[@]}"; do
    echo -e "  [$((i+1))] ${CLIENT_LIST[$i]}"
done
echo -e "  [0] Отмена операции"

# Запрос выбора у администратора
read -p "Выберите номер пользователя для удаления: " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -le 0 ] || [ "$CHOICE" -gt ${#CLIENT_LIST[@]} ]; then
    echo -e "${BLUE}Операция отменена.${NC}"
    exit 0
fi

# Определяем имя выбранного пользователя
TARGET_USER="${CLIENT_LIST[$((CHOICE-1))]}"

echo -e "\n${RED}Вы собираетесь полностью удалить пользователя: $TARGET_USER${NC}"
read -p "Вы уверены? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY][eE][sS]$ ]] && [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
    echo -e "${BLUE}Удаление отменено.${NC}"
    exit 0
fi

# Создаем резервную копию текущего рабочего конфига
sudo cp "$SERVER_CONFIG_PATH" "${SERVER_CONFIG_PATH}.bak"

echo -e "${BLUE}Модификация конфигурации сервера...${NC}"

# [ИСПРАВЛЕНО] Изменение JSON сначала происходит в памяти, защищая файл на диске
MODIFIED_JSON=$(sudo jq --arg email "$TARGET_USER" '.inbounds[0].settings.clients |= del(.[] | select(.email == $email))' "$SERVER_CONFIG_PATH")

# Валидация: если на выходе jq получили мусор, останавливаемся
if [ -z "$MODIFIED_JSON" ] || [ "$MODIFIED_JSON" == "null" ]; then
    echo -e "${RED}Критическая ошибка: jq повредил структуру при удалении. Отмена записи!${NC}"
    exit 1
fi

# Записываем проверенный JSON на диск
echo "$MODIFIED_JSON" | jq . | sudo tee "$SERVER_CONFIG_PATH" > /dev/null

# Удаляем файл конфигурации клиента на диске, если он существует
TARGET_FILE="${CLIENTS_DIR}/${TARGET_USER}.txt"
if [ -f "$TARGET_FILE" ]; then
    sudo rm -f "$TARGET_FILE"
    echo -e "Файл конфигурации ${YELLOW}${TARGET_USER}.txt${NC} успешно удален."
else
    echo -e "${YELLOW}Предупреждение: Файл $TARGET_FILE не был найден на диске, запись удалена только из config.json${NC}"
fi

# ------------------------------------------------------------------------------
# Перезапуск службы Xray и проверка её работоспособности
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}Перезапуск службы xray.service для применения изменений...${NC}"
sudo systemctl restart xray.service

if sudo systemctl is-active --quiet xray.service; then
    echo -e "${GREEN}=== Пользователь $TARGET_USER успешно удален со всех инстансов! ===${NC}"
    echo -e "Бэкап старого конфига сохранен в: ${BLUE}${SERVER_CONFIG_PATH}.bak${NC}"
else
    echo -e "${RED}Критическая ошибка: Xray упал после удаления пользователя. Восстанавливаем бэкап...${NC}"
    sudo cp "${SERVER_CONFIG_PATH}.bak" "$SERVER_CONFIG_PATH"
    sudo systemctl restart xray.service
    echo -e "${GREEN}Работа сервера восстановлена из резервной копии.${NC}"
    exit 1
fi