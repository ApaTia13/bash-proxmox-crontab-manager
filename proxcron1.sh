#!/bin/bash

# Proxmox Cron Manager для обычного пользователя
# Управление задачами cron для ВМ и контейнеров Proxmox

# Устанавливаем локаль C для предсказуемого вывода
export LANG=C
export LC_ALL=C

# Цвета для оформления
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
DEFAULT='\033[0m'

# Запрет запуска от root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Ошибка: Запуск от root запрещён. Используйте обычного пользователя с правами sudo.${DEFAULT}" >&2
    exit 1
fi

# Полные пути к командам Proxmox
PCT_CMD="/usr/sbin/pct"
QM_CMD="/usr/sbin/qm"

# Проверка наличия команд
if [ ! -x "$PCT_CMD" ] || [ ! -x "$QM_CMD" ]; then
    echo -e "${RED}Ошибка: Команды pct или qm не найдены. Убедитесь, что скрипт запускается на хосте Proxmox.${DEFAULT}"
    exit 1
fi

# Определяем директорию скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Получаем хост и IP
HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')

# Проверка/создание обёртки для выполнения задач
ensure_wrapper() {
    local wrapper="$SCRIPT_DIR/proxcron_wrapper.sh"
    if [ ! -f "$wrapper" ]; then
        echo -e "${YELLOW}Обёртка для выполнения задач не найдена. Создаю...${DEFAULT}" >&2
        cat > "$wrapper" <<'EOF'
#!/bin/bash

# Обёртка для выполнения команд Proxmox из cron
# Использование: proxcron_wrapper.sh "команда" ["описание"]

# Определяем директорию скрипта
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# Получаем хост и IP
HOSTNAME=$(hostname)
LOCAL_IP=$(hostname -I | awk '{print $1}')

# Конфиг Telegram
CONFIG_FILE="$HOME/.proxcron.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    TELEGRAM_TOKEN=""
    TELEGRAM_CHAT_ID=""
fi

# Проверка наличия curl
check_curl() {
    if ! command -v curl &>/dev/null; then
        echo "curl не установлен, уведомления в Telegram не будут отправлены" >&2
        return 1
    fi
    return 0
}

# Функция отправки сообщения в Telegram
send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        if check_curl; then
            curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/sendMessage" \
                -d chat_id="$TELEGRAM_CHAT_ID" \
                -d text="$message" \
                -d parse_mode="HTML" >/dev/null 2>&1
        fi
    fi
}

# Функция проверки состояния VM/CT и необходимости выполнения действия
check_and_execute() {
    local command="$1"
    local description="$2"

    local cmd_type=""
    local action=""
    local id=""

    if [[ "$command" =~ sudo[[:space:]]+/usr/sbin/(qm|pct)[[:space:]]+([a-z]+)[[:space:]]+([0-9]+) ]]; then
        cmd_type="${BASH_REMATCH[1]}"
        action="${BASH_REMATCH[2]}"
        id="${BASH_REMATCH[3]}"
    else
        echo "Не удалось распарсить команду, выполняю напрямую: $command" >&2
        eval "$command"
        return $?
    fi

    local status_cmd=""
    if [ "$cmd_type" = "qm" ]; then
        status_cmd="sudo /usr/sbin/qm status $id"
    else
        status_cmd="sudo /usr/sbin/pct status $id"
    fi

    local status_output
    status_output=$(eval "$status_cmd" 2>&1)
    local status_exit=$?

    if [ $status_exit -ne 0 ]; then
        echo "Ошибка получения статуса для $cmd_type $id: $status_output" >&2
        return $status_exit
    fi

    local should_execute=1
    local skip_reason=""

    if [[ "$status_output" =~ status:[[:space:]]*(.+) ]]; then
        current_status="${BASH_REMATCH[1]}"
    else
        local error_msg="Не удалось распарсить статус для $cmd_type $id: $status_output"
        echo "$error_msg" >&2
        local log_date=$(date '+%Y-%m-%d %H:%M:%S')
        local error_log="$LOG_DIR/parser_errors.log"
        echo "[$log_date] $error_msg (команда: $command)" >> "$error_log"
        if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            MESSAGE="<b>⚠️ Ошибка парсинга статуса в обёртке</b>%0A"
            MESSAGE+="<b>Хост:</b> $HOSTNAME ($LOCAL_IP)%0A"
            MESSAGE+="<b>Команда:</b> <code>$command</code>%0A"
            MESSAGE+="<b>Описание:</b> $description%0A"
            MESSAGE+="<b>Вывод статуса:</b> $status_output"
            send_telegram "$MESSAGE"
        fi
        eval "$command"
        return $?
    fi

    case "$action" in
        start)
            if [ "$current_status" = "running" ]; then
                should_execute=0
                skip_reason="$cmd_type $id уже запущен"
            fi
            ;;
        stop|shutdown)
            if [ "$current_status" = "stopped" ]; then
                should_execute=0
                skip_reason="$cmd_type $id уже остановлен"
            fi
            ;;
        reboot)
            if [ "$current_status" != "running" ]; then
                should_execute=0
                skip_reason="$cmd_type $id не запущен, перезагрузка невозможна"
            fi
            ;;
        suspend)
            if [ "$current_status" != "running" ]; then
                should_execute=0
                skip_reason="$cmd_type $id не запущен, приостановка невозможна"
            fi
            ;;
        resume)
            if [ "$current_status" = "running" ]; then
                should_execute=0
                skip_reason="$cmd_type $id уже запущен, возобновление не требуется"
            fi
            ;;
        *)
            should_execute=1
            ;;
    esac

    if [ $should_execute -eq 0 ]; then
        echo "Пропускаю выполнение: $skip_reason" >&2
        local log_date=$(date '+%Y-%m-%d %H:%M:%S')
        local log_file="$LOG_DIR/execution_$(date '+%Y-%m-%d').log"
        {
            echo "[$log_date] Хост: $HOSTNAME"
            echo "[$log_date] IP: $LOCAL_IP"
            echo "[$log_date] Команда: $command"
            echo "[$log_date] Описание: $description"
            echo "[$log_date] Пропущено: $skip_reason"
            echo "----------------------------------------"
        } >> "$log_file"
        return 0
    fi

    eval "$command"
    return $?
}

# Получаем аргументы
COMMAND="$1"
DESCRIPTION="${2:-$COMMAND}"

if [ -z "$COMMAND" ]; then
    echo "Ошибка: не указана команда" >&2
    exit 1
fi

# Текущая дата для лога
LOG_DATE=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="$LOG_DIR/execution_$(date '+%Y-%m-%d').log"

# Выполняем команду через функцию проверки
OUTPUT=$(check_and_execute "$COMMAND" "$DESCRIPTION" 2>&1)
EXIT_CODE=$?

# Логируем результат
{
    echo "[$LOG_DATE] Хост: $HOSTNAME"
    echo "[$LOG_DATE] IP: $LOCAL_IP"
    echo "[$LOG_DATE] Команда: $COMMAND"
    echo "[$LOG_DATE] Описание: $DESCRIPTION"
    echo "[$LOG_DATE] Код возврата: $EXIT_CODE"
    if [ -n "$OUTPUT" ]; then
        echo "[$LOG_DATE] Вывод: $OUTPUT"
    fi
    echo "----------------------------------------"
} >> "$LOG_FILE"

# Если ошибка, отправляем в Telegram
if [ $EXIT_CODE -ne 0 ]; then
    if [ ${#OUTPUT} -gt 500 ]; then
        OUTPUT="${OUTPUT:0:500}... (обрезано)"
    fi
    MESSAGE="<b>❌ Ошибка выполнения задачи cron</b>%0A"
    MESSAGE+="<b>Хост:</b> $HOSTNAME ($LOCAL_IP)%0A"
    MESSAGE+="<b>Команда:</b> <code>$COMMAND</code>%0A"
    MESSAGE+="<b>Описание:</b> $DESCRIPTION%0A"
    MESSAGE+="<b>Код возврата:</b> $EXIT_CODE%0A"
    MESSAGE+="<b>Вывод:</b> $OUTPUT"
    send_telegram "$MESSAGE"
fi

exit $EXIT_CODE
EOF
        chmod +x "$wrapper"
        echo -e "${GREEN}Обёртка создана: $wrapper${DEFAULT}" >&2
    elif [ ! -x "$wrapper" ]; then
        chmod +x "$wrapper"
    fi
}
ensure_wrapper

# Файл личного crontab
BACKUP_DIR="$HOME/.cron.backups"
TEMP_CRON_FILE="/tmp/crontab.$$"

# Настройка логирования действий пользователя
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

TODAY=$(date +%Y-%m-%d)
ACTION_LOG_FILE="$LOG_DIR/actions_$TODAY.log"

log_action() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$HOSTNAME ($LOCAL_IP)] - $message" >> "$ACTION_LOG_FILE"
}

rotate_logs() {
    find "$LOG_DIR" -name "actions_*.log" -type f -mtime +30 -delete 2>/dev/null
    find "$LOG_DIR" -name "execution_*.log" -type f -mtime +30 -delete 2>/dev/null
}
rotate_logs

rotate_backups() {
    if [ -d "$BACKUP_DIR" ]; then
        find "$BACKUP_DIR" -name "crontab.backup.*" -type f -mtime +30 -delete 2>/dev/null
        echo -e "${GREEN}Очистка бекапов: удалены файлы старше 30 дней${DEFAULT}" >&2
    fi
}
rotate_backups

# Загрузка конфигурации Telegram
CONFIG_FILE="$HOME/.proxcron.conf"
if [ -f "$CONFIG_FILE" ]; then
    if [ "$(stat -c %a "$CONFIG_FILE")" != "600" ]; then
        echo -e "${YELLOW}Предупреждение: файл $CONFIG_FILE имеет права $(stat -c %a "$CONFIG_FILE"). Рекомендуется chmod 600${DEFAULT}" >&2
    fi
    source "$CONFIG_FILE"
else
    TELEGRAM_TOKEN=""
    TELEGRAM_CHAT_ID=""
fi

# Функции пользовательского интерфейса
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
    echo -e "${BLUE}║${DEFAULT} 0) Выход                           ${BLUE}║${DEFAULT}"
    echo -e "${BLUE}╚════════════════════════════════════╝${DEFAULT}"
}

pause() {
    echo -e "${YELLOW}Нажмите Enter для продолжения...${DEFAULT}" >&2
    read -r
}

# Функция подтверждения с поддержкой отмены
confirm_action() {
    local action=$1
    local item=$2
    while true; do
        echo -en "${YELLOW}Вы хотите $action $item? (y/n/c): ${DEFAULT}" >&2
        read -r confirm
        case "$confirm" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            [Cc]|[Cc]ancel) return 2 ;;
            *) echo -e "${RED}Неверный ввод. Пожалуйста, введите y, n или c.${DEFAULT}" >&2 ;;
        esac
    done
}

# Функции резервного копирования
create_backup() {
    mkdir -p "$BACKUP_DIR" 2>/dev/null
    local backup_file="$BACKUP_DIR/crontab.backup.$(date +%Y%m%d_%H%M%S)"
    if crontab -l > "$backup_file" 2>/dev/null; then
        echo -e "${GREEN}Создан backup: $backup_file${DEFAULT}" >&2
        BACKUP_FILE="$backup_file"
        return 0
    else
        echo -e "${YELLOW}Предупреждение: текущий crontab пуст или отсутствует, backup не создан${DEFAULT}" >&2
        BACKUP_FILE=""
        return 0
    fi
}

restore_backup() {
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        echo -e "${YELLOW}Попытка восстановления из бэкапа $BACKUP_FILE${DEFAULT}" >&2
        if crontab "$BACKUP_FILE"; then
            echo -e "${GREEN}Восстановление выполнено${DEFAULT}" >&2
            return 0
        else
            echo -e "${RED}Критическая ошибка: не удалось восстановить бэкап!${DEFAULT}" >&2
            return 1
        fi
    fi
    return 1
}

reload_cron() {
    echo -e "${GREEN}Изменения вступили в силу${DEFAULT}" >&2
}

safe_write() {
    local temp_file=$1
    local backup_success=false

    if create_backup; then
        backup_success=true
    else
        echo -e "${YELLOW}Продолжаем без бэкапа...${DEFAULT}" >&2
    fi

    if crontab "$temp_file" 2>/dev/null; then
        echo -e "${GREEN}✓ Изменения сохранены${DEFAULT}" >&2
        reload_cron
        return 0
    else
        echo -e "${RED}Ошибка при установке нового crontab${DEFAULT}" >&2
        if $backup_success; then
            restore_backup
        fi
        return 1
    fi
}

# Функция преобразования cron-выражения в человекочитаемый вид
cron_to_human() {
    local cron_str="$1"

    if [[ "$cron_str" =~ ^@([a-zA-Z]+) ]]; then
        case "${BASH_REMATCH[1]}" in
            reboot)   echo "при каждой загрузке системы" ;;
            yearly)   echo "раз в год (1 января в 00:00)" ;;
            annually) echo "раз в год (1 января в 00:00)" ;;
            monthly)  echo "раз в месяц (1 числа в 00:00)" ;;
            weekly)   echo "раз в неделю (в воскресенье в 00:00)" ;;
            daily)    echo "каждый день в 00:00" ;;
            hourly)   echo "каждый час в 00 минут" ;;
            *)        echo "специальное: $cron_str" ;;
        esac
        return
    fi

    local minute=$(echo "$cron_str" | awk '{print $1}')
    local hour=$(echo "$cron_str" | awk '{print $2}')
    local day=$(echo "$cron_str" | awk '{print $3}')
    local month=$(echo "$cron_str" | awk '{print $4}')
    local weekday=$(echo "$cron_str" | awk '{print $5}')

    if [ "$minute" = "*" ] && [ "$hour" = "*" ] && [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$weekday" = "*" ]; then
        echo "каждую минуту"
        return
    fi

    format_time() {
        printf "%02d:%02d" "$1" "$2" 
    }

    weekday_name() {
        case $(( $1 % 7 )) in
            0) echo "воскресенье" ;;
            1) echo "понедельник" ;;
            2) echo "вторник" ;;
            3) echo "среда" ;;
            4) echo "четверг" ;;
            5) echo "пятница" ;;
            6) echo "суббота" ;;
        esac
    }

    month_name() {
        case $1 in
             1) echo "января" ;;
             2) echo "февраля" ;;
             3) echo "марта" ;;
             4) echo "апреля" ;;
             5) echo "мая" ;;
             6) echo "июня" ;;
             7) echo "июля" ;;
             8) echo "августа" ;;
             9) echo "сентября" ;;
            10) echo "октября" ;;
            11) echo "ноября" ;;
            12) echo "декабря" ;;
             *) echo "месяца $1" ;;
        esac
    }

    if [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$weekday" = "*" ]; then
        if [[ "$hour" =~ ^[0-9]+$ ]] && [[ "$minute" =~ ^[0-9]+$ ]]; then
            echo "ежедневно в $(format_time "$hour" "$minute")"
            return
        fi
    fi

    if [ "$day" = "*" ] && [ "$month" = "*" ] && [[ "$weekday" =~ ^[0-7]$ ]]; then
        if [[ "$hour" =~ ^[0-9]+$ ]] && [[ "$minute" =~ ^[0-9]+$ ]]; then
            echo "каждый $(weekday_name "$weekday") в $(format_time "$hour" "$minute")"
            return
        fi
    fi

    if [[ "$day" =~ ^[0-9]+$ ]] && [[ "$month" =~ ^[0-9]+$ ]] && [ "$weekday" = "*" ]; then
        if [[ "$hour" =~ ^[0-9]+$ ]] && [[ "$minute" =~ ^[0-9]+$ ]]; then
            echo "$day $(month_name "$month") в $(format_time "$hour" "$minute") ежегодно"
            return
        fi
    fi

    if [[ "$day" =~ ^[0-9]+$ ]] && [ "$month" = "*" ] && [ "$weekday" = "*" ]; then
        if [[ "$hour" =~ ^[0-9]+$ ]] && [[ "$minute" =~ ^[0-9]+$ ]]; then
            echo "$day числа каждого месяца в $(format_time "$hour" "$minute")"
            return
        fi
    fi

    if [[ "$minute" =~ ^\*/([0-9]+)$ ]] && [ "$hour" = "*" ] && [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$weekday" = "*" ]; then
        echo "каждые ${BASH_REMATCH[1]} минут"
        return
    fi

    if [ "$minute" = "0" ] && [[ "$hour" =~ ^\*/([0-9]+)$ ]] && [ "$day" = "*" ] && [ "$month" = "*" ] && [ "$weekday" = "*" ]; then
        echo "каждые ${BASH_REMATCH[1]} часов"
        return
    fi

    echo "сложное расписание: $minute $hour $day $month $weekday"
}

# Функции валидации cron-задач
check_time_field() {
    local field=$1
    local name=$2
    local min=$3
    local max=$4

    [ "$field" = "*" ] && return 0

    IFS=',' read -ra parts <<< "$field"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)/([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            local step=${BASH_REMATCH[3]}
            if [ "$start" -lt "$min" ] || [ "$end" -gt "$max" ] || [ "$step" -le 0 ]; then
                echo -e "${RED}Ошибка: Неверный диапазон с шагом '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start=${BASH_REMATCH[1]}
            local end=${BASH_REMATCH[2]}
            if [ "$start" -lt "$min" ] || [ "$end" -gt "$max" ] || [ "$start" -gt "$end" ]; then
                echo -e "${RED}Ошибка: Неверный диапазон '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^\*/([0-9]+)$ ]]; then
            local step=${BASH_REMATCH[1]}
            if [ "$step" -le 0 ]; then
                echo -e "${RED}Ошибка: Неверный шаг '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^([0-9]+)/([0-9]+)$ ]]; then
            local val=${BASH_REMATCH[1]}
            local step=${BASH_REMATCH[2]}
            if [ "$val" -lt "$min" ] || [ "$val" -gt "$max" ] || [ "$step" -le 0 ]; then
                echo -e "${RED}Ошибка: Неверное значение/шаг '$part' в поле '$name'${DEFAULT}" >&2
                return 1
            fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [ "$part" -lt "$min" ] || [ "$part" -gt "$max" ]; then
                echo -e "${RED}Ошибка: Значение $part в поле '$name' должно быть в диапазоне $min-$max${DEFAULT}" >&2
                return 1
            fi
        else
            echo -e "${RED}Ошибка: Некорректный формат '$part' в поле '$name'${DEFAULT}" >&2
            return 1
        fi
    done
    return 0
}

check_syntax() {
    local task=$1

    if [ -z "$task" ]; then
        echo -e "${RED}Ошибка: Задача не может быть пустой${DEFAULT}" >&2
        return 1
    fi

    if [[ "$task" =~ ^@[a-zA-Z]+\ +(.+)$ ]]; then
        local special="${BASH_REMATCH[0]%% *}"
        local command="${BASH_REMATCH[1]}"
        case "$special" in
            @reboot|@yearly|@annually|@monthly|@weekly|@daily|@hourly)
                if [ -z "$command" ]; then
                    echo -e "${RED}Ошибка: Не указана команда${DEFAULT}" >&2
                    return 1
                fi
                echo -e "${GREEN}✓ Корректный специальный синтаксис: $special${DEFAULT}" >&2
                return 0
                ;;
            *)
                echo -e "${RED}Ошибка: Неизвестный специальный параметр '$special'${DEFAULT}" >&2
                echo -e "${YELLOW}Допустимые: @reboot, @yearly, @annually, @monthly, @weekly, @daily, @hourly${DEFAULT}" >&2
                return 1
                ;;
        esac
    fi

    local fields=$(echo "$task" | awk '{print NF}')
    if [ "$fields" -lt 6 ]; then
        echo -e "${RED}Ошибка: Недостаточно полей в задаче (минимум 6: минуты часы дни месяцы дни_недели команда)${DEFAULT}" >&2
        return 1
    fi

    local minute=$(echo "$task" | awk '{print $1}')
    local hour=$(echo "$task" | awk '{print $2}')
    local day=$(echo "$task" | awk '{print $3}')
    local month=$(echo "$task" | awk '{print $4}')
    local weekday=$(echo "$task" | awk '{print $5}')
    local command=$(echo "$task" | cut -d' ' -f6-)

    if [ -z "$command" ]; then
        echo -e "${RED}Ошибка: Не указана команда${DEFAULT}" >&2
        return 1
    fi

    check_time_field "$minute" "минуты" 0 59 || return 1
    check_time_field "$hour" "часы" 0 23 || return 1
    check_time_field "$day" "дни" 1 31 || return 1
    check_time_field "$month" "месяцы" 1 12 || return 1
    check_time_field "$weekday" "дни_недели" 0 7 || return 1

    echo -e "${GREEN}✓ Синтаксис корректный${DEFAULT}" >&2
    return 0
}

# Функции для работы с Proxmox
get_containers() {
    sudo $PCT_CMD list 2>/dev/null | awk 'NR>1 {print $1 " " $2}'
}

get_vms() {
    sudo $QM_CMD list 2>/dev/null | awk 'NR>1 {print $1 " " $2}'
}

# Парсинг строки вида "1,3,5-7" в массив чисел
parse_number_list() {
    local input=$1
    local -n result=$2
    result=()
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}
            end=${BASH_REMATCH[2]}
            for ((i=start; i<=end; i++)); do
                result+=($i)
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            result+=($part)
        else
            echo -e "${RED}Неверный формат: $part${DEFAULT}" >&2
            return 1
        fi
    done
}

# Множественный выбор контейнеров
select_multiple_containers() {
    SELECTED_IDS=()
    local containers=()
    while IFS= read -r line; do
        containers+=("$line")
    done < <(get_containers)

    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${RED}Нет доступных контейнеров.${DEFAULT}" >&2
        return 1
    fi

    echo -e "${CYAN}Доступные контейнеры:${DEFAULT}" >&2
    for i in "${!containers[@]}"; do
        echo "$((i+1))) ${containers[$i]}" >&2
    done

    while true; do
        echo -e "${YELLOW}Введите номера через запятую или диапазон (например, 1,3,5-7) или введите 'c' для отмены:${DEFAULT}" >&2
        read -r choice
        if [[ "$choice" =~ ^[Cc]$ ]] || [[ "$choice" =~ ^[Cc]ancel$ ]]; then
            return 1
        fi
        if [ -z "$choice" ]; then
            continue
        fi

        local indices=()
        if ! parse_number_list "$choice" indices; then
            echo -e "${RED}Неверный формат. Попробуйте снова.${DEFAULT}" >&2
            continue
        fi

        local selected_ids=()
        local valid=true
        for idx in "${indices[@]}"; do
            if [ "$idx" -ge 1 ] && [ "$idx" -le ${#containers[@]} ]; then
                local line="${containers[$((idx-1))]}"
                local id=$(echo "$line" | awk '{print $1}')
                selected_ids+=("$id")
            else
                echo -e "${RED}Неверный номер: $idx${DEFAULT}" >&2
                valid=false
                break
            fi
        done
        if $valid; then
            SELECTED_IDS=("${selected_ids[@]}")
            return 0
        fi
    done
}

# Множественный выбор VM
select_multiple_vms() {
    SELECTED_IDS=()
    local vms=()
    while IFS= read -r line; do
        vms+=("$line")
    done < <(get_vms)

    if [ ${#vms[@]} -eq 0 ]; then
        echo -e "${RED}Нет доступных виртуальных машин.${DEFAULT}" >&2
        return 1
    fi

    echo -e "${CYAN}Доступные виртуальные машины:${DEFAULT}" >&2
    for i in "${!vms[@]}"; do
        echo "$((i+1))) ${vms[$i]}" >&2
    done

    while true; do
        echo -e "${YELLOW}Введите номера через запятую или диапазон (например, 1,3,5-7) или введите 'c' для отмены:${DEFAULT}" >&2
        read -r choice
        if [[ "$choice" =~ ^[Cc]$ ]] || [[ "$choice" =~ ^[Cc]ancel$ ]]; then
            return 1
        fi
        if [ -z "$choice" ]; then
            continue
        fi

        local indices=()
        if ! parse_number_list "$choice" indices; then
            echo -e "${RED}Неверный формат. Попробуйте снова.${DEFAULT}" >&2
            continue
        fi

        local selected_ids=()
        local valid=true
        for idx in "${indices[@]}"; do
            if [ "$idx" -ge 1 ] && [ "$idx" -le ${#vms[@]} ]; then
                local line="${vms[$((idx-1))]}"
                local id=$(echo "$line" | awk '{print $1}')
                selected_ids+=("$id")
            else
                echo -e "${RED}Неверный номер: $idx${DEFAULT}" >&2
                valid=false
                break
            fi
        done
        if $valid; then
            SELECTED_IDS=("${selected_ids[@]}")
            return 0
        fi
    done
}

# Функция выбора действия
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

        if [[ "$action_choice" =~ ^[Cc]$ ]] || [[ "$action_choice" =~ ^[Cc]ancel$ ]]; then
            return 1
        fi
        if [ -z "$action_choice" ]; then
            continue
        fi

        local base_cmd=""
        case $action_choice in
            1) base_cmd="start" ;;
            2) base_cmd="shutdown" ;;
            3) base_cmd="stop" ;;
            4) base_cmd="reboot" ;;
            5) base_cmd="suspend" ;;
            6) base_cmd="resume" ;;
            *)
                echo -e "${RED}Неверный выбор. Пожалуйста, введите число от 1 до 6.${DEFAULT}" >&2
                continue
                ;;
        esac

        if [ "$type" = "container" ]; then
            echo "sudo $PCT_CMD $base_cmd"
        else
            echo "sudo $QM_CMD $base_cmd"
        fi
        return 0
    done
}

# Функции для совместимости
select_container() {
    local containers=()
    while IFS= read -r line; do
        containers+=("$line")
    done < <(get_containers)

    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${RED}Нет доступных контейнеров.${DEFAULT}" >&2
        return 1
    fi

    echo -e "${CYAN}Доступные контейнеры:${DEFAULT}" >&2
    for i in "${!containers[@]}"; do
        echo "$((i+1))) ${containers[$i]}" >&2
    done

    local choice
    read -r -e -p "Выберите номер контейнера: " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#containers[@]} ]; then
        echo -e "${RED}Неверный выбор.${DEFAULT}" >&2
        return 1
    fi

    local selected="${containers[$((choice-1))]}"
    echo "$selected" | awk '{print $1}'
    return 0
}

select_vm() {
    local vms=()
    while IFS= read -r line; do
        vms+=("$line")
    done < <(get_vms)

    if [ ${#vms[@]} -eq 0 ]; then
        echo -e "${RED}Нет доступных виртуальных машин.${DEFAULT}" >&2
        return 1
    fi

    echo -e "${CYAN}Доступные виртуальные машины:${DEFAULT}" >&2
    for i in "${!vms[@]}"; do
        echo "$((i+1))) ${vms[$i]}" >&2
    done

    local choice
    read -r -e -p "Выберите номер VM: " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#vms[@]} ]; then
        echo -e "${RED}Неверный выбор.${DEFAULT}" >&2
        return 1
    fi

    local selected="${vms[$((choice-1))]}"
    echo "$selected" | awk '{print $1}'
    return 0
}

select_action() {
    local type=$1
    local id=$2
    echo -e "${CYAN}Выберите действие:${DEFAULT}" >&2
    echo "1) Запустить" >&2
    echo "2) Мягко выключить (shutdown)" >&2
    echo "3) Немедленно выключить (stop)" >&2
    echo "4) Перезагрузить (reboot)" >&2
    echo "5) Приостановить (suspend)" >&2
    echo "6) Возобновить (resume)" >&2
    read -r -e -p "Ваш выбор (1-6): " action_choice

    if [ -z "$action_choice" ]; then
        echo -e "${YELLOW}Действие отменено${DEFAULT}" >&2
        return 1
    fi

    local base_cmd=""
    case $action_choice in
        1) base_cmd="start" ;;
        2) base_cmd="shutdown" ;;
        3) base_cmd="stop" ;;
        4) base_cmd="reboot" ;;
        5) base_cmd="suspend" ;;
        6) base_cmd="resume" ;;
        *)
            echo -e "${RED}Неверный выбор.${DEFAULT}" >&2
            return 1
            ;;
    esac

    if [ "$type" = "container" ]; then
        echo "sudo $PCT_CMD $base_cmd $id"
    else
        echo "sudo $QM_CMD $base_cmd $id"
    fi
    return 0
}

generate_cron_line() {
    local schedule=$1
    local command=$2
    echo "$schedule $command"
}

get_proxmox_tasks() {
    tasks=()
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
            tasks+=("$line")
        fi
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

# Функция множественного выбора задач из crontab
select_multiple_tasks() {
    SELECTED_TASK_INDICES=()
    if [ ${#tasks[@]} -eq 0 ]; then
        echo -e "${RED}Нет задач для выбора.${DEFAULT}" >&2
        return 1
    fi

    echo -e "${CYAN}Доступные задачи:${DEFAULT}" >&2
    for i in "${!tasks[@]}"; do
        echo "$((i+1))) ${tasks[$i]}" >&2
    done

    while true; do
        echo -e "${YELLOW}Введите номера задач через запятую или диапазон (например, 1,3,5-7) или введите 'c' для отмены:${DEFAULT}" >&2
        read -r choice
        if [[ "$choice" =~ ^[Cc]$ ]] || [[ "$choice" =~ ^[Cc]ancel$ ]]; then
            return 1
        fi
        if [ -z "$choice" ]; then
            continue
        fi

        local indices=()
        if ! parse_number_list "$choice" indices; then
            echo -e "${RED}Неверный формат. Попробуйте снова.${DEFAULT}" >&2
            continue
        fi

        local selected_indices=()
        local valid=true
        for idx in "${indices[@]}"; do
            if [ "$idx" -ge 1 ] && [ "$idx" -le ${#tasks[@]} ]; then
                selected_indices+=($((idx-1)))
            else
                echo -e "${RED}Неверный номер: $idx (допустимо от 1 до ${#tasks[@]})${DEFAULT}" >&2
                valid=false
                break
            fi
        done
        if $valid; then
            SELECTED_TASK_INDICES=("${selected_indices[@]}")
            return 0
        fi
    done
}

# Добавляет новые задачи Proxmox
add_task() {
    echo -e "${GREEN}Добавление новых задач Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    local type=""
    local type_display=""
    while true; do
        echo -e "${CYAN}Выберите тип:${DEFAULT}" >&2
        echo "1) Виртуальная машина (VM)" >&2
        echo "2) Контейнер (LXC)" >&2
        echo -e "${YELLOW}Введите номер (1-2) или 'c' для отмены:${DEFAULT}" >&2
        read -r type_choice
        if [[ "$type_choice" =~ ^[Cc]$ ]] || [[ "$type_choice" =~ ^[Cc]ancel$ ]]; then
            return 0
        fi
        if [ -z "$type_choice" ]; then
            continue
        fi
        case $type_choice in
            1)
                type="vm"
                type_display="Виртуальная машина"
                if ! select_multiple_vms; then
                    return 0
                fi
                break
                ;;
            2)
                type="container"
                type_display="Контейнер"
                if ! select_multiple_containers; then
                    return 0
                fi
                break
                ;;
            *)
                echo -e "${RED}Неверный выбор. Пожалуйста, введите 1 или 2.${DEFAULT}" >&2
                continue
                ;;
        esac
    done

    local base_cmd
    base_cmd=$(select_action_base "$type")
    if [ $? -ne 0 ] || [ -z "$base_cmd" ]; then
        return 0
    fi

    show_task_format_info

    local wrapper_path="$SCRIPT_DIR/proxcron_wrapper.sh"
    local schedule=""

    while true; do
        echo -e "${CYAN}Введите cron-расписание (5 полей, например: 0 2 * * * или @daily) или введите 'c' для отмены:${DEFAULT}" >&2
        read -r -e -p "Расписание: " schedule
        if [[ "$schedule" =~ ^[Cc]$ ]] || [[ "$schedule" =~ ^[Cc]ancel$ ]]; then
            return 0
        fi
        if [ -z "$schedule" ]; then
            continue
        fi

        local test_id="${SELECTED_IDS[0]}"
        local test_cmd="$base_cmd $test_id"
        local test_wrapper_call="$wrapper_path '$(printf "%s" "$test_cmd" | sed "s/'/'\\\\''/g")' '$type_display №$test_id'"
        local test_full_task=$(generate_cron_line "$schedule" "$test_wrapper_call")

        if ! check_syntax "$test_full_task"; then
            echo -e "${RED}Ошибка в синтаксисе расписания. Попробуйте снова.${DEFAULT}" >&2
            continue
        fi

        echo -e "${YELLOW}Будут добавлены следующие задачи:${DEFAULT}" >&2
        for id in "${SELECTED_IDS[@]}"; do
            local cmd="$base_cmd $id"
            local wrapper_call="$wrapper_path '$(printf "%s" "$cmd" | sed "s/'/'\\\\''/g")' '$type_display №$id'"
            local task=$(generate_cron_line "$schedule" "$wrapper_call")
            echo "  $task" >&2
        done

        confirm_action "добавить" "эти задачи"
        local confirm_result=$?
        if [ $confirm_result -eq 0 ]; then
            break
        elif [ $confirm_result -eq 2 ]; then
            return 0
        else
            continue
        fi
    done

    local temp_file="$TEMP_CRON_FILE"
    crontab -l > "$temp_file" 2>/dev/null || true

    for id in "${SELECTED_IDS[@]}"; do
        local cmd="$base_cmd $id"
        local wrapper_call="$wrapper_path '$(printf "%s" "$cmd" | sed "s/'/'\\\\''/g")' '$type_display №$id'"
        local task=$(generate_cron_line "$schedule" "$wrapper_call")
        echo "$task" >> "$temp_file"
    done

    if safe_write "$temp_file"; then
        for id in "${SELECTED_IDS[@]}"; do
            local cmd="$base_cmd $id"
            local wrapper_call="$wrapper_path '$(printf "%s" "$cmd" | sed "s/'/'\\\\''/g")' '$type_display №$id'"
            local task=$(generate_cron_line "$schedule" "$wrapper_call")
            log_action "ДОБАВЛЕНИЕ: $task"
        done
        echo -e "${GREEN}Задачи добавлены.${DEFAULT}" >&2
    else
        echo -e "${RED}Не удалось добавить задачи${DEFAULT}" >&2
    fi
    rm -f "$temp_file"
    pause
}

# Функция для извлечения команды из строки задачи cron
extract_command_from_cron_line() {
    local line="$1"
    if [[ "$line" =~ ^@[a-zA-Z]+[[:space:]]+ ]]; then
        echo "$line" | awk '{$1=""; sub(/^[[:space:]]+/, ""); print}'
    else
        echo "$line" | awk '{$1=$2=$3=$4=$5=""; sub(/^[[:space:]]+/, ""); print}'
    fi
}

# Редактирование задач
edit_task() {
    echo -e "${GREEN}Редактирование задач Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    tasks=()
    get_proxmox_tasks

    if [ ${#tasks[@]} -eq 0 ]; then
        echo -e "${RED}Нет задач Proxmox для редактирования${DEFAULT}" >&2
        pause
        return 1
    fi

    if ! select_multiple_tasks; then
        pause
        return 0
    fi

    local wrapper_path="$SCRIPT_DIR/proxcron_wrapper.sh"
    local schedule=""

    while true; do
        echo -e "${CYAN}Введите новое cron-расписание (5 полей, например: 0 2 * * * или @daily) или введите 'c' для отмены:${DEFAULT}" >&2
        read -r -e -p "Расписание: " schedule
        if [[ "$schedule" =~ ^[Cc]$ ]] || [[ "$schedule" =~ ^[Cc]ancel$ ]]; then
            return 0
        fi
        if [ -z "$schedule" ]; then
            continue
        fi

        local first_idx="${SELECTED_TASK_INDICES[0]}"
        local old_task="${tasks[$first_idx]}"
        local old_command=$(extract_command_from_cron_line "$old_task")
        local new_task="$schedule $old_command"
        if ! check_syntax "$new_task"; then
            echo -e "${RED}Ошибка в синтаксисе расписания. Попробуйте снова.${DEFAULT}" >&2
            continue
        fi

        echo -e "${YELLOW}Будут изменены следующие задачи:${DEFAULT}" >&2
        for idx in "${SELECTED_TASK_INDICES[@]}"; do
            local old="${tasks[$idx]}"
            local cmd=$(extract_command_from_cron_line "$old")
            local new="$schedule $cmd"
            echo "  Было: $old" >&2
            echo "  Станет: $new" >&2
        done

        confirm_action "применить изменения" "к выбранным задачам"
        local confirm_result=$?
        if [ $confirm_result -eq 0 ]; then
            break
        elif [ $confirm_result -eq 2 ]; then
            return 0
        else
            continue
        fi
    done

    local temp_file="$TEMP_CRON_FILE"
    crontab -l > "$temp_file" 2>/dev/null || true
    local new_temp_file="${temp_file}.new"
    > "$new_temp_file"

    local count=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
            local found=false
            for idx in "${SELECTED_TASK_INDICES[@]}"; do
                if [ $count -eq $idx ]; then
                    local cmd=$(extract_command_from_cron_line "$line")
                    local new_line="$schedule $cmd"
                    echo "$new_line" >> "$new_temp_file"
                    found=true
                    break
                fi
            done
            if ! $found; then
                echo "$line" >> "$new_temp_file"
            fi
            ((count++))
        else
            echo "$line" >> "$new_temp_file"
        fi
    done < "$temp_file"
    mv "$new_temp_file" "$temp_file"

    if safe_write "$temp_file"; then
        for idx in "${SELECTED_TASK_INDICES[@]}"; do
            local old="${tasks[$idx]}"
            local cmd=$(extract_command_from_cron_line "$old")
            local new="$schedule $cmd"
            log_action "РЕДАКТИРОВАНИЕ: $old -> $new"
        done
        echo -e "${GREEN}Задачи отредактированы.${DEFAULT}" >&2
    else
        echo -e "${RED}Не удалось отредактировать задачи${DEFAULT}" >&2
    fi
    rm -f "$temp_file"
    pause
}

# Удаление задач
delete_task() {
    echo -e "${GREEN}Удаление задач Proxmox${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    tasks=()
    get_proxmox_tasks

    if [ ${#tasks[@]} -eq 0 ]; then
        echo -e "${RED}Нет задач Proxmox для удаления${DEFAULT}" >&2
        pause
        return 1
    fi

    if ! select_multiple_tasks; then
        pause
        return 0
    fi

    echo -e "${YELLOW}Будут удалены следующие задачи:${DEFAULT}" >&2
    for idx in "${SELECTED_TASK_INDICES[@]}"; do
        echo "  ${tasks[$idx]}" >&2
    done

    confirm_action "удалить" "выбранные задачи"
    local confirm_result=$?
    if [ $confirm_result -eq 0 ]; then
        local temp_file="$TEMP_CRON_FILE"
        crontab -l > "$temp_file" 2>/dev/null || true
        local new_temp_file="${temp_file}.new"
        > "$new_temp_file"

        local count=0
        while IFS= read -r line; do
            if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]] && [[ "$line" =~ pct|qm ]]; then
                local found=false
                for idx in "${SELECTED_TASK_INDICES[@]}"; do
                    if [ $count -eq $idx ]; then
                        found=true
                        break
                    fi
                done
                if ! $found; then
                    echo "$line" >> "$new_temp_file"
                fi
                ((count++))
            else
                echo "$line" >> "$new_temp_file"
            fi
        done < "$temp_file"
        mv "$new_temp_file" "$temp_file"

        if safe_write "$temp_file"; then
            for idx in "${SELECTED_TASK_INDICES[@]}"; do
                log_action "УДАЛЕНИЕ: ${tasks[$idx]}"
            done
            echo -e "${GREEN}Задачи удалены.${DEFAULT}" >&2
        else
            echo -e "${RED}Не удалось удалить задачи${DEFAULT}" >&2
        fi
        rm -f "$temp_file"
    elif [ $confirm_result -eq 2 ]; then
        return 0
    else
        return 0
    fi
    pause
}

# Просмотр задач
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

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}Нет активных задач Proxmox${DEFAULT}" >&2
    fi
    echo "-----------------------------------" >&2
    pause
}

# Проверка статуса cron сервиса
check_cron_status() {
    echo -e "${GREEN}Статус cron сервиса:${DEFAULT}" >&2
    echo "-----------------------------------" >&2

    local service_name=""
    if systemctl list-units --full -all | grep -Fq 'cron.service'; then
        service_name="cron"
    elif systemctl list-units --full -all | grep -Fq 'crond.service'; then
        service_name="crond"
    fi

    if [ -n "$service_name" ]; then
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            echo -e "Статус: ${GREEN}Активен${DEFAULT} ✓" >&2
        else
            echo -e "Статус: ${RED}Не активен${DEFAULT} ✗" >&2
        fi

        if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
            echo -e "Автозапуск: ${GREEN}Включен${DEFAULT}" >&2
        else
            echo -e "Автозапуск: ${RED}Отключен${DEFAULT}" >&2
        fi

        echo "-----------------------------------" >&2
        systemctl status "$service_name" --no-pager -l
    else
        echo -e "${RED}Сервис cron не найден${DEFAULT}" >&2
    fi
    echo "-----------------------------------" >&2
    pause
}

# Просмотр логов
view_logs() {
    echo -e "${GREEN}Логи действий пользователя (последние 20 записей):${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    if [ -f "$ACTION_LOG_FILE" ]; then
        tail -n 20 "$ACTION_LOG_FILE" >&2
    else
        echo -e "${YELLOW}Лог действий за сегодня ещё не создан.${DEFAULT}" >&2
    fi
    echo
    echo -e "${GREEN}Логи выполнения задач (последние 20 записей):${DEFAULT}" >&2
    echo "-----------------------------------" >&2
    local exec_log="$LOG_DIR/execution_$TODAY.log"
    if [ -f "$exec_log" ]; then
        tail -n 20 "$exec_log" >&2
    else
        echo -e "${YELLOW}Лог выполнения за сегодня ещё не создан.${DEFAULT}" >&2
    fi
    echo "-----------------------------------" >&2
    pause
}

# Основной цикл программы
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
        0) echo -e "${GREEN}До свидания!${DEFAULT}" >&2; exit 0 ;;
        *) echo -e "${RED}Неверный выбор. Пожалуйста, выберите 0-6${DEFAULT}" >&2; pause ;;
    esac
done
