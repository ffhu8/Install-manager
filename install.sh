#!/bin/bash

# ==============================================================================
# Единый установщик Xray Manager через cURL (Проверенная Версия)
# Скачивает компоненты, выставляет права и интегрирует команды в систему.
# ==============================================================================

set -e

# Цвета для красивого вывода
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0;m'


GITHUB_USER="ffhu8"
GITHUB_REPO="Install-manager"
GITHUB_BRANCH="main"

# Базовый URL для скачивания сырых файлов (Raw)
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Папка, куда мы сохраним сами скрипты, чтобы они не мешались в root-директории
TARGET_DIR="/usr/local/share/xray-manager"

echo -e "${BLUE}=== Начало установки Xray Manager ===${NC}"

# Проверяем и устанавливаем curl, если его нет в системе
if ! command -v curl &> /dev/null; then
    echo -e "${YELLOW}curl не найден. Устанавливаем...${NC}"
    sudo apt-get update -y && sudo apt-get install -y curl
fi

# Создаем системную папку для хранения утилит
sudo mkdir -p "$TARGET_DIR"

echo -e "${BLUE}Скачивание компонентов с GitHub...${NC}"

# Функция для безопасного скачивания с таймаутами и проверкой ошибок
download_script() {
    local file_name=$1
    echo -e "Загрузка ${YELLOW}${file_name}${NC}..."
    
    # Скачиваем с защитой от зависания сети (--connect-timeout и --retry)
    sudo curl -sSL --connect-timeout 10 --retry 3 "${BASE_URL}/${file_name}" -o "${TARGET_DIR}/${file_name}"
    
    # Проверка: если файл пустой или содержит 404 ошибку (например, неверный ник/репозиторий)
    if [ ! -s "${TARGET_DIR}/${file_name}" ] || grep -q "404: Not Found" "${TARGET_DIR}/${file_name}"; then
        echo -e "${RED}Ошибка: Не удалось скачать ${file_name}. Проверьте имя пользователя и репозиторий в install.sh${NC}"
        sudo rm -f "${TARGET_DIR}/${file_name}"
        exit 1
    fi
    
    # Выдаем права на исполнение
    sudo chmod +x "${TARGET_DIR}/${file_name}"
}

# Скачиваем все три скрипта
download_script "generate_vless.sh"
download_script "update_clients.sh"
download_script "remove_clients.sh"

echo -e "${BLUE}Интеграция команд в систему...${NC}"

# Гарантируем наличие папки для бинарников и создаем символические ссылки
sudo mkdir -p /usr/local/bin
sudo ln -sf "${TARGET_DIR}/generate_vless.sh" /usr/local/bin/xray-gen
sudo ln -sf "${TARGET_DIR}/update_clients.sh" /usr/local/bin/xray-add
sudo ln -sf "${TARGET_DIR}/remove_clients.sh" /usr/local/bin/xray-rm

echo -e "\n${GREEN}=== Установка успешно завершена! ===${NC}"
echo -e "Скрипты изолированы в папке: ${BLUE}${TARGET_DIR}/${NC}"
echo -e "Вам доступны глобальные команды из любой точки терминала:\n"
echo -e "  ${GREEN}xray-gen${NC}  - Полная инициализация сервера Reality (с нуля)"
echo -e "  ${GREEN}xray-add${NC}  - Добавление новых клиентов/генерация новых ссылок"
echo -e "  ${GREEN}xray-rm${NC}   - Безопасное удаление клиентов из конфига и диска"
echo -e "--------------------------------------------------------"