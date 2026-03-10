#!/bin/bash

# ------------> Proxmox Cron Manager <------------

export LANG=C
export LC_ALL=C
umask 027

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
DEFAULT='\033[0m'

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Ошибка: Запуск от root запрещён. Используйте обычного пользователя с правами sudo.${DEFAULT}" >&2
    exit 1
fi

PCT_CMD="/usr/sbin/pct"
QM_CMD="/usr/sbin/qm"

if [ ! -x "$PCT_CMD" ] || [ ! -x "$QM_CMD" ]; then
    echo -e "${RED}Ошибка: Команды pct или qm не найдены. Убедитесь, что скрипт запускается на хосте Proxmox.${DEFAULT}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"

HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')

# ------------> Безопасные временные файлы <------------
create_temp_file() {
    mktemp 2>/dev/null || mktemp -p /tmp proxcron.XXXXXX
}

# ------------> Настройка прав доступа <------------
setup_permissions() {
    chown $USER "$SCRIPT_DIR" 2>/dev/null || true
    chmod 750 "$SCRIPT_DIR" 2>/dev/null || true
    mkdir -p "$SCRIPT_DIR/logs" "$HOME/.cron.backups"
    chown $USER "$SCRIPT_DIR/logs" "$HOME/.cron.backups" 2>/dev/null || true
    chmod 750 "$SCRIPT_DIR/logs" "$HOME/.cron.backups" 2>/dev/null || true
}

# ------------> Создание обёртки для cron-задач <------------
ensure_wrapper() {
    local wrapper="$SCRIPT_DIR/proxcron_wrapper.sh"
    if [ ! -f "$wrapper" ]; then
        echo -e "${YELLOW}Обёртка для выполнения задач не найдена. Создаю...${DEFAULT}" >&2
        cat > "$wrapper" <<'EOF'
#!/bin/bash
umask 027
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')
CONFIG_FILE="$HOME/.proxcron.conf"
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; else TELEGRAM_TOKEN=""; TELEGRAM_CHAT_ID=""; fi

# Экранирование HTML-сущностей для Telegram
escape_html() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g;' <<< "$1"
}

# Отправка уведомления в Telegram
send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && command -v curl &>/dev/null; then
        local escaped_message=$(escape_html "$message")
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$escaped_message" \
            -d parse_mode="HTML" >/dev/null 2>&1
    fi
}

# Проверка состояния и выполнение команды
check_and_execute() {
    local command="$1" description="$2" cmd_type action id extra_args

    if [[ "$command" =~ ^sudo[[:space:]]+/usr/sbin/(qm|pct)[[:space:]]+([a-z]+)[[:space:]]+([0-9]+)([[:space:]]+.*)?$ ]]; then
        cmd_type="${BASH_REMATCH[1]}"
        action="${BASH_REMATCH[2]}"
        id="${BASH_REMATCH[3]}"
        extra_args="${BASH_REMATCH[4]}"

        case "$action" in
            start|stop|shutdown|reboot|suspend|resume|status) ;;
            *)
                echo "Недопустимое действие: $action" >&2
                return 1
                ;;
        esac

        local status_output=$(sudo /usr/sbin/${cmd_type} status "$id" 2>&1)
        local status_exit=$?
        if [ $status_exit -ne 0 ]; then
            sudo /usr/sbin/${cmd_type} $action "$id" $extra_args
            return $?
        fi

        local current_status
        if [[ "$status_output" =~ status:[[:space:]]*(.+) ]]; then
            current_status="${BASH_REMATCH[1]}"
        else
            sudo /usr/sbin/${cmd_type} $action "$id" $extra_args
            return $?
        fi

        case "$action" in
            start)   [ "$current_status" = "running" ] && return 0 ;;
            stop|shutdown) [ "$current_status" = "stopped" ] && return 0 ;;
            reboot|suspend) [ "$current_status" != "running" ] && return 0 ;;
            resume)  [ "$current_status" = "running" ] && return 0 ;;
        esac

        sudo /usr/sbin/${cmd_type} $action "$id" $extra_args
    else
        echo "Ошибка: недопустимый формат команды: $command" >&2
        return 1
    fi
}

COMMAND="$1"
DESCRIPTION="${2:-$COMMAND}"
[ -z "$COMMAND" ] && exit 1

LOG_DATE=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$LOG_DIR/execution_$(date '+%Y-%m-%d').log"
OUTPUT=$(check_and_execute "$COMMAND" "$DESCRIPTION" 2>&1)
EXIT_CODE=$?

{
    echo "[$LOG_DATE] Хост: $HOSTNAME"
    echo "[$LOG_DATE] IP: $LOCAL_IP"
    echo "[$LOG_DATE] Команда: $COMMAND"
    echo "[$LOG_DATE] Описание: $DESCRIPTION"
    echo "[$LOG_DATE] Код возврата: $EXIT_CODE"
    [ -n "$OUTPUT" ] && echo "[$LOG_DATE] Вывод: $OUTPUT"
    echo "----------------------------------------"
} >> "$LOG_FILE"

[ $EXIT_CODE -ne 0 ] && send_telegram "<b>❌ Ошибка</b>%0A<b>Хост:</b> $HOSTNAME ($LOCAL_IP)%0A<b>Команда:</b> <code>$COMMAND</code>%0A<b>Описание:</b> $DESCRIPTION%0A<b>Код возврата:</b> $EXIT_CODE%0A<b>Вывод:</b> ${OUTPUT:0:500}"

exit $EXIT_CODE
EOF
        chmod 750 "$wrapper"
        chown $USER:$USER "$wrapper" 2>/dev/null || true
        echo -e "${GREEN}Обёртка создана: $wrapper${DEFAULT}" >&2
    fi
}

setup_permissions
ensure_wrapper

TEMP_CRON_FILE=$(create_temp_file) || { echo -e "${RED}Ошибка создания временного файла${DEFAULT}" >&2; exit 1; }

BACKUP_DIR="$HOME/.cron.backups"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
TODAY=$(date +%Y-%m-%d)
ACTION_LOG_FILE="$LOG_DIR/actions_$TODAY.log"
touch "$ACTION_LOG_FILE" 2>/dev/null
chmod 640 "$ACTION_LOG_FILE" 2>/dev/null || true

log_action() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$HOSTNAME ($LOCAL_IP)] - $1" >> "$ACTION_LOG_FILE"; }

rotate_logs() { find "$LOG_DIR" -name "actions_*.log" -o -name "execution_*.log" -o -name "parser_errors.log" -type f -mtime +${1:-30} -delete 2>/dev/null; }
rotate_backups() { [ -d "$BACKUP_DIR" ] && find "$BACKUP_DIR" -name "crontab.backup.*" -type f -mtime +${1:-30} -delete 2>/dev/null; }

CONFIG_FILE="$HOME/.proxcron.conf"
if [ -f "$CONFIG_FILE" ]; then
    [ "$(stat -c %a "$CONFIG_FILE")" != "600" ] && echo -e "${YELLOW}Предупреждение: файл $CONFIG_FILE имеет права $(stat -c %a "$CONFIG_FILE"). Рекомендуется chmod 600${DEFAULT}" >&2
    if grep -q -E '[;`$(){}]' "$CONFIG_FILE"; then
        echo -e "${RED}Ошибка: конфигурационный файл содержит потенциально опасные символы. Загрузка отменена.${DEFAULT}" >&2
        TELEGRAM_TOKEN=""
        TELEGRAM_CHAT_ID=""
    else
        source "$CONFIG_FILE"
    fi
else
    TELEGRAM_TOKEN=""
    TELEGRAM_CHAT_ID=""
fi

if [ "$1" = "--cleanup" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        echo -e "${YELLOW}Вы действительно хотите выполнить очистку логов и бэкапов сейчас? (y/N)${DEFAULT}" >&2
        read -r confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo -e "${GREEN}Очистка отменена.${DEFAULT}" >&2; exit 0; }
        log_action "Ручная очистка логов и бэкапов (--cleanup)"
    fi
    rotate_logs "${CLEANUP_DAYS_LOGS:-30}"
    rotate_backups "${CLEANUP_DAYS_BACKUPS:-30}"
    rm -f "$TEMP_CRON_FILE"
    exit 0
fi

rotate_logs 30
rotate_backups 30

escape_html() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g;' <<< "$1"
}

send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] && command -v curl &>/dev/null; then
        local escaped_message=$(escape_html "$message")
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$escaped_message" \
            -d parse_mode="HTML" >/dev/null 2>&1
    fi
}

# ------------> Настройка Telegram <------------
configure_telegram() {
    echo -e "${CYAN}Настройка уведомлений Telegram${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    command -v curl &>/dev/null || { echo -e "${RED}curl не установлен. Уведомления Telegram недоступны.${DEFAULT}" >&2; pause; return 1; }

    while true; do
        echo -e "${YELLOW}Введите токен бота (ввод скрыт). Для отмены введите 'c':${DEFAULT}" >&2
        read -r -s TELEGRAM_TOKEN; echo
        [[ "$TELEGRAM_TOKEN" =~ ^[Cc]$ ]] && { echo -e "${YELLOW}Настройка отменена.${DEFAULT}" >&2; pause; return 0; }
        [ -n "$TELEGRAM_TOKEN" ] && break
        echo -e "${RED}Токен не может быть пустым. Попробуйте снова.${DEFAULT}" >&2
    done

    while true; do
        echo -e "${YELLOW}Введите ваш Chat ID. Для отмены введите 'c':${DEFAULT}" >&2
        read -r TELEGRAM_CHAT_ID
        [[ "$TELEGRAM_CHAT_ID" =~ ^[Cc]$ ]] && { echo -e "${YELLOW}Настройка отменена.${DEFAULT}" >&2; pause; return 0; }
        [ -n "$TELEGRAM_CHAT_ID" ] && break
        echo -e "${RED}Chat ID не может быть пустым. Попробуйте снова.${DEFAULT}" >&2
    done

    if confirm_simple "сохранить" "данные"; then
        umask 077
        cat > "$CONFIG_FILE" <<EOF
TELEGRAM_TOKEN='$TELEGRAM_TOKEN'
TELEGRAM_CHAT_ID='$TELEGRAM_CHAT_ID'
EOF
        umask 027
        chmod 600 "$CONFIG_FILE"
        echo -e "${GREEN}Конфигурация сохранена в $CONFIG_FILE (права 600)${DEFAULT}" >&2
        echo -e "${YELLOW}Отправляем тестовое сообщение...${DEFAULT}" >&2
        if send_telegram "<b>✅ Тест</b>%0AНастройка Telegram выполнена успешно."; then
            echo -e "${GREEN}✓ Тестовое сообщение отправлено.${DEFAULT}" >&2
        else
            echo -e "${RED}✗ Ошибка отправки. Проверьте токен и chat ID.${DEFAULT}" >&2
        fi
    else
        echo -e "${YELLOW}Сохранение отменено.${DEFAULT}" >&2
    fi
    pause
}

# ------------> Отображение главного меню <------------
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════╗${DEFAULT}"
    echo -e "${BLUE}║${GREEN}        Proxmox Cron Manager        ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}╠════════════════════════════════════╣${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 1) Просмотр задач Proxmox          ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 2) Добавить задачу Proxmox         ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 3) Редактировать задачи Proxmox    ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 4) Удалить задачи Proxmox          ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 5) Статус cron сервиса             ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 6) Просмотр логов                  ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 7) Настройка автоматической очистки${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 8) Настройка Telegram              ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}║${DEFAULT} 0) Выход                           ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}╚════════════════════════════════════╝${DEFAULT}"
}

pause() {
    echo -e "${YELLOW}Нажмите Enter для продолжения...${DEFAULT}" >&2
    read -r
}

confirm_simple() {
    local action=$1 item=$2
    while true; do
        echo -en "${YELLOW}Вы хотите $action $item? (y/n): ${DEFAULT}" >&2
        read -r confirm
        case "$confirm" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo -e "${RED}Неверный ввод. Пожалуйста, введите y или n.${DEFAULT}" >&2 ;;
        esac
    done
}

# ------------> Управление автоматической очисткой (пункт 7) <------------
manage_cleanup() {
    while true; do
        clear
        echo -e "${GREEN}Настройка автоматической очистки логов и бэкапов${DEFAULT}"
        echo "-----------------------------------"
        local cleanup_line=$(crontab -l 2>/dev/null | grep -F "# proxcron-cleanup" | head -1)
        if [ -n "$cleanup_line" ]; then
            echo -e "${CYAN}Текущая задача очистки:${DEFAULT}"
            echo "  $cleanup_line"
        else
            echo -e "${YELLOW}Задача очистки не настроена.${DEFAULT}"
        fi
        echo -e "Текущие сроки хранения: логи ${CLEANUP_DAYS_LOGS:-30} дн., бэкапы ${CLEANUP_DAYS_BACKUPS:-30} дн."
        echo
        echo "Выберите действие:"
        echo "1) Установить/изменить задачу очистки"
        echo "2) Удалить задачу очистки"
        echo "0) Вернуться в меню"
        read -r -e -p "Ваш выбор: " subchoice
        [ -z "$subchoice" ] && { echo -e "${RED}Неверный ввод. Попробуйте снова.${DEFAULT}"; pause; continue; }
        case $subchoice in
            1)
                echo -e "${YELLOW}Через сколько дней удалять логи? (по умолчанию 30, 'c' для отмены)${DEFAULT}"
                read -r -e -p "Дней для логов: " days_logs
                [[ "$days_logs" =~ ^[Cc]$ ]] && { echo -e "${YELLOW}Отменено.${DEFAULT}"; continue; }
                days_logs=${days_logs:-30}
                if ! [[ "$days_logs" =~ ^[0-9]+$ ]] || [ "$days_logs" -lt 1 ]; then
                    echo -e "${RED}Некорректное число. Используется 30.${DEFAULT}"; days_logs=30
                fi

                echo -e "${YELLOW}Через сколько дней удалять бэкапы? (по умолчанию 30, 'c' для отмены)${DEFAULT}"
                read -r -e -p "Дней для бэкапов: " days_backups
                [[ "$days_backups" =~ ^[Cc]$ ]] && { echo -e "${YELLOW}Отменено.${DEFAULT}"; continue; }
                days_backups=${days_backups:-30}
                if ! [[ "$days_backups" =~ ^[0-9]+$ ]] || [ "$days_backups" -lt 1 ]; then
                    echo -e "${RED}Некорректное число. Используется 30.${DEFAULT}"; days_backups=30
                fi

                if ! confirm_simple "установить задачу очистки с новыми сроками" "(логи: $days_logs дн., бэкапы: $days_backups дн.)"; then
                    echo -e "${YELLOW}Действие отменено.${DEFAULT}"; continue
                fi

                if grep -q "^CLEANUP_DAYS_LOGS=" "$CONFIG_FILE" 2>/dev/null; then
                    sed -i "s/^CLEANUP_DAYS_LOGS=.*/CLEANUP_DAYS_LOGS=$days_logs/" "$CONFIG_FILE"
                else
                    echo "CLEANUP_DAYS_LOGS=$days_logs" >> "$CONFIG_FILE"
                fi
                if grep -q "^CLEANUP_DAYS_BACKUPS=" "$CONFIG_FILE" 2>/dev/null; then
                    sed -i "s/^CLEANUP_DAYS_BACKUPS=.*/CLEANUP_DAYS_BACKUPS=$days_backups/" "$CONFIG_FILE"
                else
                    echo "CLEANUP_DAYS_BACKUPS=$days_backups" >> "$CONFIG_FILE"
                fi
                CLEANUP_DAYS_LOGS=$days_logs
                CLEANUP_DAYS_BACKUPS=$days_backups

                local max_days=$(( days_logs > days_backups ? days_logs : days_backups ))
                local schedule
                if [ "$max_days" -ge 30 ]; then schedule="0 0 1 * *"
                elif [ "$max_days" -ge 7 ]; then schedule="0 0 * * 0"
                else schedule="0 3 * * *"
                fi

                local cron_cmd="$schedule \"$SCRIPT_PATH\" --cleanup # proxcron-cleanup"
                crontab -l 2>/dev/null | grep -vF "# proxcron-cleanup" | crontab -
                (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
                echo -e "${GREEN}Задача очистки установлена с расписанием: $schedule${DEFAULT}"
                ;;
            2)
                [ -z "$cleanup_line" ] && { echo -e "${YELLOW}Задача очистки не настроена.${DEFAULT}"; continue; }
                if ! confirm_simple "удалить задачу очистки" ""; then
                    echo -e "${YELLOW}Действие отменено.${DEFAULT}"; continue
                fi
                crontab -l 2>/dev/null | grep -vF "# proxcron-cleanup" | crontab -
                echo -e "${GREEN}Задача очистки удалена.${DEFAULT}"
                ;;
            0) break ;;
            *) echo -e "${RED}Неверный выбор.${DEFAULT}"; pause ;;
        esac
    done
}

# ------------> Работа с резервными копиями crontab <------------
create_backup() {
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    local backup_file="$BACKUP_DIR/crontab.backup.$(date +%Y%m%d_%H%M%S)"
    if crontab -l > "$backup_file" 2>/dev/null; then
        echo -e "${GREEN}Создан backup: $backup_file${DEFAULT}" >&2
        BACKUP_FILE="$backup_file"
        return 0
    else
        echo -e "${YELLOW}Предупреждение: crontab пуст, backup не создан${DEFAULT}" >&2
        BACKUP_FILE=""
        return 0
    fi
}

restore_backup() {
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] && [ -s "$BACKUP_FILE" ] && grep -q '[^[:space:]]' "$BACKUP_FILE"; then
        crontab "$BACKUP_FILE" && return 0
    fi
    return 1
}

reload_cron() { echo -e "${GREEN}Изменения вступили в силу${DEFAULT}" >&2; }

safe_write() {
    local temp_file=$1
    local backup_success=false
    if create_backup; then backup_success=true; fi
    if crontab "$temp_file" 2>/dev/null; then
        echo -e "${GREEN}✓ Изменения сохранены${DEFAULT}" >&2
        reload_cron
        return 0
    else
        echo -e "${RED}Ошибка при установке нового crontab${DEFAULT}" >&2
        $backup_success && restore_backup
        return 1
    fi
}

# ------------> Проверка синтаксиса cron-расписания <------------
check_cron_syntax() {
    local sched="$1"
    if [[ "$sched" =~ ^@(reboot|yearly|annually|monthly|weekly|daily|hourly)$ ]]; then
        return 0
    fi
    local sched_norm=$(echo "$sched" | sed -E 's/\<(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|mon|tue|wed|thu|fri|sat|sun)\>/*/gi')
    local pattern='^([0-9*,/-]+|[0-9]+) ([0-9*,/-]+|[0-9]+) ([0-9*,/-]+|[0-9]+) ([0-9*,/-]+|[0-9]+) ([0-9*,/-]+|[0-9]+)$'
    if [[ "$sched_norm" =~ $pattern ]]; then
        return 0
    fi
    return 1
}

# ------------> Преобразование cron-строки в читаемый вид <------------
cron_to_human() {
    local cron_str="$1"
    if [[ "$cron_str" =~ ^@([a-zA-Z]+) ]]; then
        case "${BASH_REMATCH[1]}" in
            reboot)   echo "при каждой загрузке системы"; return ;;
            yearly|annually) echo "раз в год (1 января в 00:00)"; return ;;
            monthly)  echo "раз в месяц (1 числа в 00:00)"; return ;;
            weekly)   echo "раз в неделю (в воскресенье в 00:00)"; return ;;
            daily)    echo "каждый день в 00:00"; return ;;
            hourly)   echo "каждый час в 00 минут"; return ;;
            *)        echo "специальное: $cron_str"; return ;;
        esac
    fi

    local minute hour day month weekday
    read -r minute hour day month weekday <<< "$(echo "$cron_str" | awk '{print $1, $2, $3, $4, $5}')"

    describe_field() {
        local field="$1" type="$2"
        [ "$field" = "*" ] && { case "$type" in minute) echo "каждую минуту"; return ;; hour) echo "каждый час"; return ;; day) echo "каждый день"; return ;; month) echo "каждый месяц"; return ;; weekday) echo "любой день недели"; return ;; esac }
        local parts; IFS=',' read -ra parts <<< "$field"
        local descriptions=()
        for part in "${parts[@]}"; do
            if [[ "$part" =~ ^([0-9]+)-([0-9]+)/([0-9]+)$ ]]; then
                case "$type" in minute) descriptions+=("с ${BASH_REMATCH[1]} по ${BASH_REMATCH[2]} каждые ${BASH_REMATCH[3]} мин") ;;
                hour) descriptions+=("с ${BASH_REMATCH[1]} по ${BASH_REMATCH[2]} каждые ${BASH_REMATCH[3]} ч") ;;
                day) descriptions+=("с ${BASH_REMATCH[1]} по ${BASH_REMATCH[2]} каждые ${BASH_REMATCH[3]} дн") ;;
                month) descriptions+=("с $(month_name ${BASH_REMATCH[1]}) по $(month_name ${BASH_REMATCH[2]}) с шагом ${BASH_REMATCH[3]} мес") ;;
                weekday) descriptions+=("с $(weekday_name ${BASH_REMATCH[1]}) по $(weekday_name ${BASH_REMATCH[2]}) с шагом ${BASH_REMATCH[3]}") ;; esac
            elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                case "$type" in minute) descriptions+=("с ${BASH_REMATCH[1]} по ${BASH_REMATCH[2]} мин") ;;
                hour) descriptions+=("с ${BASH_REMATCH[1]} по ${BASH_REMATCH[2]} ч") ;;
                day) descriptions+=("с ${BASH_REMATCH[1]} по ${BASH_REMATCH[2]} числа") ;;
                month) descriptions+=("с $(month_name ${BASH_REMATCH[1]}) по $(month_name ${BASH_REMATCH[2]})") ;;
                weekday) descriptions+=("с $(weekday_name ${BASH_REMATCH[1]}) по $(weekday_name ${BASH_REMATCH[2]})") ;; esac
            elif [[ "$part" =~ ^\*/([0-9]+)$ ]]; then
                case "$type" in minute) descriptions+=("каждые ${BASH_REMATCH[1]} мин") ;;
                hour) descriptions+=("каждые ${BASH_REMATCH[1]} ч") ;;
                day) descriptions+=("каждые ${BASH_REMATCH[1]} дн") ;;
                month) descriptions+=("каждые ${BASH_REMATCH[1]} мес") ;;
                weekday) descriptions+=("каждые ${BASH_REMATCH[1]} дн недели") ;; esac
            elif [[ "$part" =~ ^([0-9]+)/([0-9]+)$ ]]; then
                case "$type" in minute) descriptions+=("начиная с ${BASH_REMATCH[1]} каждые ${BASH_REMATCH[2]} мин") ;;
                hour) descriptions+=("начиная с ${BASH_REMATCH[1]} каждые ${BASH_REMATCH[2]} ч") ;;
                day) descriptions+=("начиная с ${BASH_REMATCH[1]} каждые ${BASH_REMATCH[2]} дн") ;;
                month) descriptions+=("начиная с $(month_name ${BASH_REMATCH[1]}) каждые ${BASH_REMATCH[2]} мес") ;;
                weekday) descriptions+=("начиная с $(weekday_name ${BASH_REMATCH[1]}) каждые ${BASH_REMATCH[2]} дн недели") ;; esac
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                case "$type" in minute) descriptions+=("$part мин") ;;
                hour) descriptions+=("$part ч") ;;
                day) descriptions+=("$part числа") ;;
                month) descriptions+=("$(month_name $part)") ;;
                weekday) descriptions+=("$(weekday_name $part)") ;; esac
            else descriptions+=("$part")
            fi
        done
        if [ ${#descriptions[@]} -eq 1 ]; then echo "${descriptions[0]}"
        else local result=""; local last_idx=$(( ${#descriptions[@]} - 1 ))
            for i in "${!descriptions[@]}"; do
                if [ $i -eq 0 ]; then result="${descriptions[$i]}"
                elif [ $i -eq $last_idx ]; then result+=" и ${descriptions[$i]}"
                else result+=", ${descriptions[$i]}"
                fi
            done
            echo "$result"
        fi
    }

    local minute_desc=$(describe_field "$minute" "minute")
    local hour_desc=$(describe_field "$hour" "hour")
    local day_desc=$(describe_field "$day" "day")
    local month_desc=$(describe_field "$month" "month")
    local weekday_desc=$(describe_field "$weekday" "weekday")

    [ "$minute" != "*" ] && [ "$hour" != "*" ] && [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$weekday" = "*" ] && { printf "каждый день в %02d:%02d" "$hour" "$minute"; return; }
    [ "$minute" != "*" ] && [ "$hour" != "*" ] && [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$weekday" != "*" ] && { printf "каждый $weekday_desc в %02d:%02d" "$hour" "$minute"; return; }
    [ "$minute" != "*" ] && [ "$hour" != "*" ] && [ "$day" != "*" ] && [ "$month" = "*" ] && [ "$weekday" = "*" ] && { printf "$day_desc каждого месяца в %02d:%02d" "$hour" "$minute"; return; }
    [ "$minute" != "*" ] && [ "$hour" != "*" ] && [ "$day" = "*" ] && [ "$month" != "*" ] && [ "$weekday" = "*" ] && { printf "каждый день в $month_desc в %02d:%02d" "$hour" "$minute"; return; }
    [ "$day" != "*" ] && [ "$month" != "*" ] && { printf "$day_desc $month_desc"; [ "$hour" != "*" ] && printf " в %02d:%02d" "$hour" "$minute"; return; }
    [ "$weekday" != "*" ] && [ "$month" != "*" ] && { printf "каждый $weekday_desc в $month_desc"; [ "$hour" != "*" ] && printf " в %02d:%02d" "$hour" "$minute"; return; }
    [ "$day" != "*" ] && [ "$weekday" != "*" ] && { printf "когда (день месяца $day_desc) ИЛИ (день недели $weekday_desc)"; [ "$hour" != "*" ] && printf " в %02d:%02d" "$hour" "$minute"; return; }

    local parts=()
    [ "$minute_desc" != "каждую минуту" ] && parts+=("минуты: $minute_desc")
    [ "$hour_desc" != "каждый час" ] && parts+=("часы: $hour_desc")
    [ "$day_desc" != "каждый день" ] && parts+=("дни: $day_desc")
    [ "$month_desc" != "каждый месяц" ] && parts+=("месяцы: $month_desc")
    [ "$weekday_desc" != "любой день недели" ] && parts+=("дни недели: $weekday_desc")
    if [ ${#parts[@]} -eq 0 ]; then echo "каждую минуту"
    else local result=""; local last_idx=$(( ${#parts[@]} - 1 ))
        for i in "${!parts[@]}"; do
            if [ $i -eq 0 ]; then result="${parts[$i]}"
            elif [ $i -eq $last_idx ]; then result+=" и ${parts[$i]}"
            else result+=", ${parts[$i]}"
            fi
        done
        echo "$result"
    fi
}

month_name() {
    case $1 in
        1) echo "января" ;; 2) echo "февраля" ;; 3) echo "марта" ;; 4) echo "апреля" ;;
        5) echo "мая" ;; 6) echo "июня" ;; 7) echo "июля" ;; 8) echo "августа" ;;
        9) echo "сентября" ;; 10) echo "октября" ;; 11) echo "ноября" ;; 12) echo "декабря" ;;
        *) echo "месяца $1" ;;
    esac
}

weekday_name() {
    case $(( $1 % 7 )) in
        0|7) echo "воскресенье" ;; 1) echo "понедельник" ;; 2) echo "вторник" ;;
        3) echo "среда" ;; 4) echo "четверг" ;; 5) echo "пятница" ;; 6) echo "суббота" ;;
    esac
}

# ------------> Функции для работы с Proxmox <------------
get_containers() { sudo $PCT_CMD list 2>/dev/null | awk 'NR>1 {print $1 " " $2}'; }
get_vms() { sudo $QM_CMD list 2>/dev/null | awk 'NR>1 {print $1 " " $2}'; }

parse_number_list() {
    local input=$1; local -n result=$2; result=()
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do result+=($i); done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then result+=($part)
        else echo -e "${RED}Неверный формат: $part${DEFAULT}" >&2; return 1
        fi
    done
}

select_multiple_containers() {
    SELECTED_IDS=()
    local containers=()
    while IFS= read -r line; do containers+=("$line"); done < <(get_containers)
    [ ${#containers[@]} -eq 0 ] && { echo -e "${RED}Нет доступных контейнеров.${DEFAULT}" >&2; return 1; }
    echo -e "${CYAN}Доступные контейнеры:${DEFAULT}" >&2
    for i in "${!containers[@]}"; do echo "$((i+1))) ${containers[$i]}" >&2; done
    while true; do
        echo -e "${YELLOW}Введите номера через запятую или диапазон (например, 1,3,5-7) или 'c' для отмены:${DEFAULT}" >&2
        read -r choice
        [[ "$choice" =~ ^[Cc]$ ]] && return 1
        [ -z "$choice" ] && continue
        local indices=()
        if ! parse_number_list "$choice" indices; then continue; fi
        local selected_ids=(); local valid=true
        for idx in "${indices[@]}"; do
            if [ "$idx" -ge 1 ] && [ "$idx" -le ${#containers[@]} ]; then
                selected_ids+=($(echo "${containers[$((idx-1))]}" | awk '{print $1}'))
            else echo -e "${RED}Неверный номер: $idx${DEFAULT}" >&2; valid=false; break
            fi
        done
        $valid && { SELECTED_IDS=("${selected_ids[@]}"); return 0; }
    done
}

select_multiple_vms() {
    SELECTED_IDS=()
    local vms=()
    while IFS= read -r line; do vms+=("$line"); done < <(get_vms)
    [ ${#vms[@]} -eq 0 ] && { echo -e "${RED}Нет доступных виртуальных машин.${DEFAULT}" >&2; return 1; }
    echo -e "${CYAN}Доступные виртуальные машины:${DEFAULT}" >&2
    for i in "${!vms[@]}"; do echo "$((i+1))) ${vms[$i]}" >&2; done
    while true; do
        echo -e "${YELLOW}Введите номера через запятую или диапазон (например, 1,3,5-7) или 'c' для отмены:${DEFAULT}" >&2
        read -r choice
        [[ "$choice" =~ ^[Cc]$ ]] && return 1
        [ -z "$choice" ] && continue
        local indices=()
        if ! parse_number_list "$choice" indices; then continue; fi
        local selected_ids=(); local valid=true
        for idx in "${indices[@]}"; do
            if [ "$idx" -ge 1 ] && [ "$idx" -le ${#vms[@]} ]; then
                selected_ids+=($(echo "${vms[$((idx-1))]}" | awk '{print $1}'))
            else echo -e "${RED}Неверный номер: $idx${DEFAULT}" >&2; valid=false; break
            fi
        done
        $valid && { SELECTED_IDS=("${selected_ids[@]}"); return 0; }
    done
}

select_action_base() {
    local type=$1
    while true; do
        echo -e "${CYAN}Выберите действие:${DEFAULT}" >&2
        echo "1) Запустить" >&2
        echo "2) Мягко выключить (shutdown)" >&2
        echo "3) Немедленно выключить (stop)" >&2
        echo "4) Перезагрузить (reboot)" >&2
        echo "5) Приостановить (suspend)" >&2
        echo "6) Возобновить (resume)" >&2
        echo -e "${YELLOW}Введите номер действия (1-6) или 'c' для отмены:${DEFAULT}" >&2
        read -r action_choice
        [[ "$action_choice" =~ ^[Cc]$ ]] && return 1
        [ -z "$action_choice" ] && continue
        case $action_choice in
            1) echo "sudo $([ "$type" = "container" ] && echo "$PCT_CMD" || echo "$QM_CMD") start"; return 0 ;;
            2) echo "sudo $([ "$type" = "container" ] && echo "$PCT_CMD" || echo "$QM_CMD") shutdown"; return 0 ;;
            3) echo "sudo $([ "$type" = "container" ] && echo "$PCT_CMD" || echo "$QM_CMD") stop"; return 0 ;;
            4) echo "sudo $([ "$type" = "container" ] && echo "$PCT_CMD" || echo "$QM_CMD") reboot"; return 0 ;;
            5) echo "sudo $([ "$type" = "container" ] && echo "$PCT_CMD" || echo "$QM_CMD") suspend"; return 0 ;;
            6) echo "sudo $([ "$type" = "container" ] && echo "$PCT_CMD" || echo "$QM_CMD") resume"; return 0 ;;
            *) echo -e "${RED}Неверный выбор. Введите число от 1 до 6.${DEFAULT}" >&2 ;;
        esac
    done
}

generate_cron_line() { echo "$1 $2"; }

get_proxmox_tasks() {
    tasks=()
    while IFS= read -r line; do
        [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]] && tasks+=("$line")
    done < <(crontab -l 2>/dev/null)
}

show_task_format_info() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${DEFAULT}" >&2
    echo -e "${GREEN}ФОРМАТ ЗАДАЧИ CRON:${DEFAULT}" >&2
    echo -e "${YELLOW}минуты часы дни месяцы дни_недели${DEFAULT}" >&2
    echo >&2
    echo -e "${GREEN}СПЕЦИАЛЬНЫЕ ЗНАЧЕНИЯ:${DEFAULT}" >&2
    echo -e "  ${PURPLE}@reboot${DEFAULT}    - при каждом запуске системы" >&2
    echo -e "  ${PURPLE}@yearly${DEFAULT}    - 0 0 1 1 * (раз в год)" >&2
    echo -e "  ${PURPLE}@annually${DEFAULT}  - 0 0 1 1 * (раз в год)" >&2
    echo -e "  ${PURPLE}@monthly${DEFAULT}   - 0 0 1 * * (раз в месяц)" >&2
    echo -e "  ${PURPLE}@weekly${DEFAULT}    - 0 0 * * 0 (раз в неделю)" >&2
    echo -e "  ${PURPLE}@daily${DEFAULT}     - 0 0 * * * (каждый день)" >&2
    echo -e "  ${PURPLE}@hourly${DEFAULT}    - 0 * * * * (каждый час)" >&2
    echo >&2
    echo -e "${GREEN}СИМВОЛЫ:${DEFAULT}" >&2
    echo -e "  ${YELLOW}*${DEFAULT} - любое значение" >&2
    echo -e "  ${YELLOW},${DEFAULT} - список значений (1,2,3)" >&2
    echo -e "  ${YELLOW}-${DEFAULT} - диапазон значений (1-5)" >&2
    echo -e "  ${YELLOW}/${DEFAULT} - шаг значений (*/5 = каждые 5)" >&2
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${DEFAULT}" >&2
}

select_multiple_tasks() {
    SELECTED_TASK_INDICES=()
    [ ${#tasks[@]} -eq 0 ] && { echo -e "${RED}Нет задач для выбора.${DEFAULT}" >&2; return 1; }
    echo -e "${CYAN}Доступные задачи:${DEFAULT}" >&2
    for i in "${!tasks[@]}"; do echo "$((i+1))) ${tasks[$i]}" >&2; done
    while true; do
        echo -e "${YELLOW}Введите номера задач через запятую или диапазон (например, 1,3,5-7) или 'c' для отмены:${DEFAULT}" >&2
        read -r choice
        [[ "$choice" =~ ^[Cc]$ ]] && return 1
        [ -z "$choice" ] && continue
        local indices=()
        if ! parse_number_list "$choice" indices; then continue; fi
        local selected_indices=(); local valid=true
        for idx in "${indices[@]}"; do
            if [ "$idx" -ge 1 ] && [ "$idx" -le ${#tasks[@]} ]; then
                selected_indices+=($((idx-1)))
            else echo -e "${RED}Неверный номер: $idx (допустимо от 1 до ${#tasks[@]})${DEFAULT}" >&2; valid=false; break
            fi
        done
        $valid && { SELECTED_TASK_INDICES=("${selected_indices[@]}"); return 0; }
    done
}

extract_command_from_cron_line() {
    local line="$1"
    if [[ "$line" =~ ^@[a-zA-Z]+[[:space:]]+ ]]; then
        echo "$line" | awk '{$1=""; sub(/^[[:space:]]+/, ""); print}'
    else
        echo "$line" | awk '{$1=$2=$3=$4=$5=""; sub(/^[[:space:]]+/, ""); print}'
    fi
}

# ------------> Добавление задачи (пункт 2) <------------
add_task() {
    echo -e "${GREEN}Добавление новых задач Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    local type type_display
    while true; do
        echo -e "${CYAN}Выберите тип:${DEFAULT}" >&2
        echo "1) Виртуальная машина (VM)" >&2
        echo "2) Контейнер (LXC)" >&2
        echo -e "${YELLOW}Введите номер (1-2) или 'c' для отмены:${DEFAULT}" >&2
        read -r type_choice
        [[ "$type_choice" =~ ^[Cc]$ ]] && return 0
        [ -z "$type_choice" ] && continue
        case $type_choice in
            1) type="vm"; type_display="Виртуальная машина"; select_multiple_vms || return 0; break ;;
            2) type="container"; type_display="Контейнер"; select_multiple_containers || return 0; break ;;
            *) echo -e "${RED}Неверный выбор. Введите 1 или 2.${DEFAULT}" >&2 ;;
        esac
    done

    local base_cmd
    base_cmd=$(select_action_base "$type") || return 0
    show_task_format_info

    local wrapper_path="$SCRIPT_DIR/proxcron_wrapper.sh"
    local schedule=""
    while true; do
        echo -e "${CYAN}Введите cron-расписание (5 полей, например: 0 2 * * * или @daily) или 'c' для отмены:${DEFAULT}" >&2
        read -r -e -p "Расписание: " schedule
        [[ "$schedule" =~ ^[Cc]$ ]] && return 0
        [ -z "$schedule" ] && continue

        if ! check_cron_syntax "$schedule"; then
            echo -e "${RED}Ошибка в синтаксисе расписания. Попробуйте снова.${DEFAULT}" >&2
            continue
        fi

        echo -e "${YELLOW}Будут добавлены следующие задачи:${DEFAULT}" >&2
        for id in "${SELECTED_IDS[@]}"; do
            local cmd="$base_cmd $id"
            local wrapper_call="$wrapper_path '$(printf "%s" "$cmd" | sed "s/'/'\\\\''/g")' '$type_display №$id'"
            echo "  $(generate_cron_line "$schedule" "$wrapper_call")" >&2
        done

        if confirm_simple "добавить" "эти задачи"; then break; fi
    done

    local temp_file="$TEMP_CRON_FILE"
    crontab -l > "$temp_file" 2>/dev/null || true
    for id in "${SELECTED_IDS[@]}"; do
        local cmd="$base_cmd $id"
        local wrapper_call="$wrapper_path '$(printf "%s" "$cmd" | sed "s/'/'\\\\''/g")' '$type_display №$id'"
        echo "$(generate_cron_line "$schedule" "$wrapper_call")" >> "$temp_file"
    done

    if safe_write "$temp_file"; then
        for id in "${SELECTED_IDS[@]}"; do
            log_action "ДОБАВЛЕНИЕ: $(generate_cron_line "$schedule" "$base_cmd $id через обёртку")"
        done
        echo -e "${GREEN}Задачи добавлены.${DEFAULT}" >&2
    else
        echo -e "${RED}Не удалось добавить задачи${DEFAULT}" >&2
    fi
    rm -f "$temp_file"
    pause
}

# ------------> Редактирование задачи (пункт 3) <------------
edit_task() {
    echo -e "${GREEN}Редактирование задач Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    tasks=(); get_proxmox_tasks
    [ ${#tasks[@]} -eq 0 ] && { echo -e "${RED}Нет задач Proxmox для редактирования${DEFAULT}" >&2; pause; return 1; }
    select_multiple_tasks || { pause; return 0; }

    local wrapper_path="$SCRIPT_DIR/proxcron_wrapper.sh"
    local schedule=""
    while true; do
        echo -e "${CYAN}Введите новое cron-расписание (5 полей, например: 0 2 * * * или @daily) или 'c' для отмены:${DEFAULT}" >&2
        read -r -e -p "Расписание: " schedule
        [[ "$schedule" =~ ^[Cc]$ ]] && return 0
        [ -z "$schedule" ] && continue

        local first_idx="${SELECTED_TASK_INDICES[0]}"
        local old_task="${tasks[$first_idx]}"
        local old_command=$(extract_command_from_cron_line "$old_task")
        if ! check_cron_syntax "$schedule"; then
            echo -e "${RED}Ошибка в синтаксисе расписания. Попробуйте снова.${DEFAULT}" >&2
            continue
        fi

        echo -e "${YELLOW}Будут изменены следующие задачи:${DEFAULT}" >&2
        for idx in "${SELECTED_TASK_INDICES[@]}"; do
            local old="${tasks[$idx]}"
            local cmd=$(extract_command_from_cron_line "$old")
            echo "  Было: $old" >&2
            echo "  Станет: $schedule $cmd" >&2
        done

        if confirm_simple "применить изменения" "к выбранным задачам"; then break; fi
    done

    local temp_file="$TEMP_CRON_FILE"
    crontab -l > "$temp_file" 2>/dev/null || true
    local new_temp_file=$(create_temp_file) || { echo -e "${RED}Ошибка создания временного файла${DEFAULT}" >&2; return 1; }
    > "$new_temp_file"
    local count=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
            local found=false
            for idx in "${SELECTED_TASK_INDICES[@]}"; do
                if [ $count -eq $idx ]; then
                    local cmd=$(extract_command_from_cron_line "$line")
                    echo "$schedule $cmd" >> "$new_temp_file"
                    found=true; break
                fi
            done
            if ! $found; then echo "$line" >> "$new_temp_file"; fi
            ((count++))
        else
            echo "$line" >> "$new_temp_file"
        fi
    done < "$temp_file"
    mv "$new_temp_file" "$temp_file"

    if safe_write "$temp_file"; then
        for idx in "${SELECTED_TASK_INDICES[@]}"; do
            log_action "РЕДАКТИРОВАНИЕ: ${tasks[$idx]} -> $schedule $(extract_command_from_cron_line "${tasks[$idx]}")"
        done
        echo -e "${GREEN}Задачи отредактированы.${DEFAULT}" >&2
    else
        echo -e "${RED}Не удалось отредактировать задачи${DEFAULT}" >&2
    fi
    rm -f "$temp_file"
    pause
}

# ------------> Удаление задачи (пункт 4) <------------
delete_task() {
    echo -e "${GREEN}Удаление задач Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    tasks=(); get_proxmox_tasks
    [ ${#tasks[@]} -eq 0 ] && { echo -e "${RED}Нет задач Proxmox для удаления${DEFAULT}" >&2; pause; return 1; }
    select_multiple_tasks || { pause; return 0; }

    echo -e "${YELLOW}Будут удалены следующие задачи:${DEFAULT}" >&2
    for idx in "${SELECTED_TASK_INDICES[@]}"; do echo "  ${tasks[$idx]}" >&2; done

    if ! confirm_simple "удалить" "выбранные задачи"; then pause; return 0; fi

    local temp_file="$TEMP_CRON_FILE"
    crontab -l > "$temp_file" 2>/dev/null || true
    local new_temp_file=$(create_temp_file) || { echo -e "${RED}Ошибка создания временного файла${DEFAULT}" >&2; return 1; }
    > "$new_temp_file"
    local count=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
            local found=false
            for idx in "${SELECTED_TASK_INDICES[@]}"; do
                if [ $count -eq $idx ]; then found=true; break; fi
            done
            if ! $found; then echo "$line" >> "$new_temp_file"; fi
            ((count++))
        else
            echo "$line" >> "$new_temp_file"
        fi
    done < "$temp_file"
    mv "$new_temp_file" "$temp_file"

    if safe_write "$temp_file"; then
        for idx in "${SELECTED_TASK_INDICES[@]}"; do log_action "УДАЛЕНИЕ: ${tasks[$idx]}"; done
        echo -e "${GREEN}Задачи удалены.${DEFAULT}" >&2
    else
        echo -e "${RED}Не удалось удалить задачи${DEFAULT}" >&2
    fi
    rm -f "$temp_file"
    pause
}

# ------------> Просмотр задач (пункт 1) <------------
view_tasks() {
    echo -e "${GREEN}Задачи Proxmox в личном crontab:${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    local count=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
            count=$((count+1))
            local cron_part=$(echo "$line" | awk '{for(i=1;i<=5;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
            local human_desc=$(cron_to_human "$cron_part")
            echo "$count) $line" >&2
            echo "   → $human_desc" >&2
        fi
    done < <(crontab -l 2>/dev/null)
    [ $count -eq 0 ] && echo -e "${YELLOW}Нет активных задач Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    pause
}

# ------------> Статус cron сервиса (пункт 5) <------------
check_cron_status() {
    echo -e "${GREEN}Статус cron сервиса:${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    local service_name=""
    if systemctl list-units --full -all | grep -Fq 'cron.service'; then service_name="cron"
    elif systemctl list-units --full -all | grep -Fq 'crond.service'; then service_name="crond"
    fi
    if [ -n "$service_name" ]; then
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then echo -e "Статус: ${GREEN}Активен${DEFAULT} ✓" >&2
        else echo -e "Статус: ${RED}Не активен${DEFAULT} ✗" >&2
        fi
        if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then echo -e "Автозапуск: ${GREEN}Включен${DEFAULT}" >&2
        else echo -e "Автозапуск: ${RED}Отключен${DEFAULT}" >&2
        fi
        echo "-----------------------------------" >&2
        systemctl status "$service_name" --no-pager -l
    else
        echo -e "${RED}Сервис cron не найден${DEFAULT}" >&2
    fi
    echo "-----------------------------------" >&2
    pause
}

# ------------> Просмотр логов (пункт 6) <------------
view_logs() {
    echo -e "${GREEN}Логи действий пользователя (последние 20 записей):${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    [ -f "$ACTION_LOG_FILE" ] && tail -n 20 "$ACTION_LOG_FILE" >&2 || echo -e "${YELLOW}Лог действий за сегодня ещё не создан.${DEFAULT}" >&2
    echo
    echo -e "${GREEN}Логи выполнения задач (последние 20 записей):${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    local exec_log="$LOG_DIR/execution_$TODAY.log"
    [ -f "$exec_log" ] && tail -n 20 "$exec_log" >&2 || echo -e "${YELLOW}Лог выполнения за сегодня ещё не создан.${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    pause
}

# ------------> Главный цикл меню <------------
while true; do
    show_menu
    read -r -e -p "Выберите пункт меню: " choice
    choice=$(echo "$choice" | tr -d '\r' | xargs)
    case $choice in
        1) view_tasks ;;
        2) add_task ;;
        3) edit_task ;;
        4) delete_task ;;
        5) check_cron_status ;;
        6) view_logs ;;
        7) manage_cleanup ;;
        8) configure_telegram ;;
        0) echo -e "${GREEN}До свидания!${DEFAULT}" >&2; rm -f "$TEMP_CRON_FILE"; exit 0 ;;
        *) echo -e "${RED}Неверный выбор. Пожалуйста, выберите 0-8${DEFAULT}" >&2; pause ;;
    esac
done
