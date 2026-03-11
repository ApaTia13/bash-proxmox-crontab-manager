#!/bin/bash

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Функция приветствия
show_banner() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${GREEN}     Proxmox Crontab Manager Installer      ${BLUE}║${NC}"
    echo -e "${BLUE}║${YELLOW}             by ApaTia13 (XENON)            ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo
}

# Функция подтверждения
confirm() {
    local prompt="$1"
    local answer
    while true; do
        echo -en "${YELLOW}$prompt (y/n): ${NC}"
        read -r answer
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo -e "${RED}Пожалуйста, введите y или n.${NC}" ;;
        esac
    done
}

# Функция для выполнения команд с учётом прав
run_cmd() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Улучшенная функция загрузки с GitHub
github_download() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_delay=2
    local attempt=1
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    if command -v curl &>/dev/null; then
        while [ $attempt -le $max_retries ]; do
            echo "Попытка загрузки $attempt из $max_retries..." >&2
            if curl -k -L -f -sS -o "$output" -A "$ua" --connect-timeout 10 --retry 3 --retry-delay 2 "$url"; then
                return 0
            fi
            echo "Попытка $attempt не удалась, повтор через $retry_delay сек..." >&2
            sleep $retry_delay
            attempt=$((attempt+1))
        done
        return 1
    elif command -v wget &>/dev/null; then
        while [ $attempt -le $max_retries ]; do
            echo "Попытка загрузки $attempt из $max_retries..." >&2
            if wget --no-check-certificate -q -O "$output" --user-agent="$ua" --timeout=10 --tries=3 "$url"; then
                return 0
            fi
            echo "Попытка $attempt не удалась, повтор через $retry_delay сек..." >&2
            sleep $retry_delay
            attempt=$((attempt+1))
        done
        return 1
    else
        echo "Ни curl, ни wget не доступны" >&2
        return 1
    fi
}

# Функция для получения списка релизов с GitHub
fetch_releases() {
    local api_url="https://api.github.com/repos/ApaTia13/bash-proxmox-crontab-manager/releases"
    local releases_json
    if command -v curl &>/dev/null; then
        releases_json=$(curl -H "User-Agent: Mozilla/5.0" -s "$api_url")
    elif command -v wget &>/dev/null; then
        releases_json=$(wget --user-agent="Mozilla/5.0" -q -O - "$api_url")
    else
        return 1
    fi
    if [ $? -ne 0 ] || [ -z "$releases_json" ]; then
        return 1
    fi
    # Извлекаем значения tag_name с помощью awk
    echo "$releases_json" | awk -F'"' '{
        for(i=1;i<NF;i++) {
            if($i=="tag_name") {
                gsub(/[",]/, "", $(i+2));
                print $(i+2);
            }
        }
    }'
}

# Проверка наличия необходимых утилит
check_deps() {
    local missing=()
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        missing+=("curl или wget")
    fi
    if [ "$EUID" -ne 0 ] && ! command -v sudo &>/dev/null; then
        echo -e "${RED}Ошибка: sudo не установлен, а скрипт запущен не от root.${NC}" >&2
        echo "Установите sudo или запустите скрипт от root." >&2
        exit 1
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Отсутствуют необходимые утилиты: ${missing[*]}${NC}" >&2
        if [ "$EUID" -eq 0 ]; then
            echo "Попробуйте установить их: apt update && apt install curl" >&2
        else
            echo "Попробуйте установить их через sudo: sudo apt update && sudo apt install curl" >&2
        fi
        exit 1
    fi
}

show_banner
check_deps

TARGET_USER="proxmox-scheduler"
INSTALL_DIR="/home/$TARGET_USER/proxcron"

echo -e "Этот скрипт установит Proxmox Crontab Manager для пользователя ${CYAN}$TARGET_USER${NC}"
echo -e "Директория установки: ${GREEN}$INSTALL_DIR${NC}"
echo

# Получаем список релизов
echo -e "${YELLOW}Получаю список доступных версий с GitHub...${NC}"
RELEASES=$(fetch_releases)
if [ -z "$RELEASES" ]; then
    echo -e "${RED}Не удалось получить список релизов. Использую запасной список.${NC}"
    RELEASES="1.1.0
1.0.0"
fi

mapfile -t release_array <<< "$RELEASES"
# Удаляем возможные пустые строки
release_array=(${release_array[@]})

if [ ${#release_array[@]} -eq 0 ]; then
    echo -e "${RED}Нет доступных версий. Прерывание.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Доступные версии:${NC}"
for i in "${!release_array[@]}"; do
    echo "  $((i+1))) ${release_array[$i]}"
done
echo

# Выбор версии
VERSION=""
while [ -z "$VERSION" ]; do
    echo -en "${YELLOW}Введите номер версии (1-${#release_array[@]}): ${NC}"
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#release_array[@]} ]; then
        SELECTED_TAG="${release_array[$((choice-1))]}"
        SCRIPT_URL="https://github.com/ApaTia13/bash-proxmox-crontab-manager/releases/download/${SELECTED_TAG}/proxcron.sh"
        VERSION="$SELECTED_TAG"
    else
        echo -e "${RED}Неверный выбор. Введите число от 1 до ${#release_array[@]}.${NC}"
    fi
done

echo -e "${GREEN}Выбрана версия $VERSION${NC}"
echo

echo "Будет выполнено:"
echo "  • Создан пользователь $TARGET_USER (если не существует)"
echo "  • Создана директория $INSTALL_DIR"
echo "  • Установлен пароль для $TARGET_USER"
echo "  • Настроены sudo-права для команд qm и pct"
echo "  • Загружен скрипт менеджера (proxcron.sh) версии $VERSION"
echo "  • Установлены права доступа (750)"
echo "  • (Опционально) Добавлен alias в ~$TARGET_USER/.bash_aliases"
echo

if ! confirm "Продолжить установку?"; then
    echo -e "${YELLOW}Установка отменена.${NC}"
    exit 0
fi

# Установка curl (если отсутствует)
if ! command -v curl &>/dev/null; then
    echo -e "${YELLOW}Для отправки уведомлений в Telegram требуется curl.${NC}"
    if confirm "Установить curl сейчас?"; then
        echo "Устанавливаю curl..."
        run_cmd apt update && run_cmd apt install -y curl
    else
        echo -e "${YELLOW}Пропускаю установку curl. Уведомления Telegram будут недоступны.${NC}"
    fi
else
    echo "curl уже установлен."
fi

# Создание пользователя
if id "$TARGET_USER" &>/dev/null; then
    echo -e "${YELLOW}Пользователь $TARGET_USER уже существует. Пропускаю создание.${NC}"
else
    echo "Создаю пользователя $TARGET_USER..."
    run_cmd useradd -m -s /bin/bash "$TARGET_USER"
    echo -e "${GREEN}Пользователь $TARGET_USER создан.${NC}"
fi

# Обязательно задаём пароль
echo "Задайте пароль для пользователя $TARGET_USER:"
run_cmd passwd "$TARGET_USER"

# Создание директории установки
echo "Создаю директорию $INSTALL_DIR..."
run_cmd mkdir -p "$INSTALL_DIR"
run_cmd chown "$TARGET_USER":"$TARGET_USER" "$INSTALL_DIR"
run_cmd chmod 750 "$INSTALL_DIR"

# Загрузка скрипта
echo "Загружаю скрипт Proxmox Crontab Manager версии $VERSION..."
TMP_SCRIPT=$(mktemp)
if github_download "$SCRIPT_URL" "$TMP_SCRIPT"; then
    run_cmd mv "$TMP_SCRIPT" "$INSTALL_DIR/proxcron.sh"
    run_cmd chown "$TARGET_USER":"$TARGET_USER" "$INSTALL_DIR/proxcron.sh"
    run_cmd chmod 750 "$INSTALL_DIR/proxcron.sh"
    echo -e "${GREEN}Скрипт загружен в $INSTALL_DIR/proxcron.sh${NC}"
else
    echo -e "${RED}Не удалось загрузить скрипт. Проверьте соединение или URL: $SCRIPT_URL${NC}" >&2
    rm -f "$TMP_SCRIPT"
    exit 1
fi

# Настройка sudoers
SUDOERS_FILE="/etc/sudoers.d/$TARGET_USER"
echo "Настраиваю sudoers для $TARGET_USER..."
TEMP_SUDOERS=$(mktemp)
cat > "$TEMP_SUDOERS" <<EOF
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/qm start *, /usr/sbin/qm stop *, /usr/sbin/qm shutdown *, /usr/sbin/qm status *, /usr/sbin/qm list, /usr/sbin/qm reboot *, /usr/sbin/qm suspend *, /usr/sbin/qm resume *
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/pct start *, /usr/sbin/pct stop *, /usr/sbin/pct shutdown *, /usr/sbin/pct status *, /usr/sbin/pct list, /usr/sbin/pct reboot *, /usr/sbin/pct suspend *, /usr/sbin/pct resume *
EOF
if run_cmd visudo -c -f "$TEMP_SUDOERS" &>/dev/null; then
    run_cmd cp "$TEMP_SUDOERS" "$SUDOERS_FILE"
    run_cmd chmod 440 "$SUDOERS_FILE"
    echo -e "${GREEN}sudoers настроен.${NC}"
else
    echo -e "${RED}Ошибка в синтаксисе sudoers. Файл не установлен.${NC}"
fi
rm -f "$TEMP_SUDOERS"

# Добавление alias
if confirm "Добавить alias 'proxcron' для пользователя $TARGET_USER?"; then
    ALIAS_CMD="alias proxcron='cd $INSTALL_DIR && ./proxcron.sh'"
    TARGET_HOME=$(eval echo "~$TARGET_USER")
    ALIAS_FILE="$TARGET_HOME/.bash_aliases"
    run_cmd touch "$ALIAS_FILE" 2>/dev/null || true
    run_cmd chown "$TARGET_USER":"$TARGET_USER" "$ALIAS_FILE" 2>/dev/null || true
    echo "$ALIAS_CMD" | run_cmd tee -a "$ALIAS_FILE" >/dev/null
    echo -e "${GREEN}Alias добавлен в $ALIAS_FILE${NC}"
    echo -e "${YELLOW}Чтобы активировать, пользователь $TARGET_USER должен выполнить 'source ~/.bash_aliases' или перелогиниться.${NC}"
fi

# Финальные инструкции
echo -e "${GREEN}=== Установка завершена ===${NC}"
echo -e "Пользователь: ${CYAN}$TARGET_USER${NC}"
echo -e "Директория установки: ${YELLOW}$INSTALL_DIR${NC}"
echo -e "Для запуска менеджера переключитесь на пользователя и выполните:"
echo -e "  ${YELLOW}sudo su - $TARGET_USER${NC}"
echo -e "  ${YELLOW}cd $INSTALL_DIR && ./proxcron.sh${NC}"
echo

if confirm "Хотите переключиться на пользователя $TARGET_USER и запустить менеджер сейчас?"; then
    if [ "$EUID" -eq 0 ]; then
        su - "$TARGET_USER" -c "cd $INSTALL_DIR && ./proxcron.sh"
    else
        sudo su - "$TARGET_USER" -c "cd $INSTALL_DIR && ./proxcron.sh"
    fi
fi

exit 0
