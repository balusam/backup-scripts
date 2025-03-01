#!/bin/bash

# ==============================================================================
# УНИВЕРСАЛЬНЫЙ СКРИПТ РЕЗЕРВНОГО КОПИРОВАНИЯ СИСТЕМЫ (Версия 6.3)
# ==============================================================================
#
# Особенности:
#   - Кросс-дистрибутивная поддержка (Arch, Debian, Ubuntu, Fedora, CentOS и др.)
#   - Безопасное резервирование с обработкой исключений
#   - Поддержка Docker, баз данных и пользовательских данных
#   - Генерация скриптов восстановления
#   - Автоматическая удаление старых бэкапов (отключена по-умолчанию)
#   - Настройка уровня сжатия 0-9 (по-умолчанию 6) 
#   - Сохранять скрытые файлы по-умолчанию отключено 
#
# Запуск:
#   sudo ./system_backup.sh [ОПЦИИ]
#
# Опции:
#   -o, --output PATH  - Каталог для сохранения бэкапов
#   -h, --help         - Показать справку
#   -c, --config       - Показать текущую конфигурацию
# ==============================================================================

# Конфигурация по умолчанию
CONFIG_FILE="/etc/backup.conf"
BACKUP_PREFIX="system_backup"
RETAIN_DAYS=0                # Хранить предыдущие копии Х дней (0 очистка отключена)
BACKUP_HIDDEN=0              # Сохранять скрытые файлы (0-отключено, 1-включить)
COMPRESSION_LEVEL=6          # Уровень сжатия (1-9)

# Определение пользователя и домашней директории
ORIGINAL_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$USER}")
USER_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
DEFAULT_BACKUP_ROOT="${USER_HOME}/backups"               # Место сохранения бэкапа (по-умолчанию /home/backups)

# Цвета для вывода
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# Инициализация переменных
declare -A BACKUP_SOURCES
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_DATE=$(date +%Y-%m-%d_%H-%M-%S)
LOGFILE=""
BACKUP_DIR=""
DISTRO_ID="unknown"
DISTRO_VERSION="unknown"


# Исключаемые пути
declare -a EXCLUDE_PATTERNS=(
    "--exclude=*.lock"
    "--exclude=*.sock"
    "--exclude=*.example"
    "--exclude=/etc/webmin"
    "--exclude=/etc/NetworkManager/system-connections"
    "--exclude=/tmp/*"
    "--exclude=/var/tmp/*"
    "--exclude=/var/cache/*"
)

# Инициализация путей резервирования
init_backup_sources() {
    declare -Ag BACKUP_SOURCES=(
        ["etc_backup.tar.gz"]="/etc"
        ["usr_backup.tar.gz"]="/usr/share/hassio"
        ["home_backup.tar.gz"]="\
            ${USER_HOME}/github \
            ${USER_HOME}/digicamDB \
            ${USER_HOME}/Документы \
            ${USER_HOME}/Изображения \
            ${USER_HOME}/.bash_history \
            ${USER_HOME}/.bash_profile \
            ${USER_HOME}/.bashrc \
            ${USER_HOME}/Шаблоны \
            ${USER_HOME}/Общедоступные \
            ${USER_HOME}/.vscode \
            ${USER_HOME}/.thunderbird"
        ["cron_backup.tar.gz"]="\
            /var/spool/cron/crontabs \
            /etc/crontab \
            /etc/cron.d \
            /etc/cron.daily \
            /etc/cron.hourly \
            /etc/cron.monthly \
            /etc/cron.weekly"
        ["docker_backup.tar.gz"]="\
            /etc/docker \
            /opt/docker-compose"
        ["user_configs.tar.gz"]="\
            ${USER_HOME}/.config \
            ${USER_HOME}/.themes \
            ${USER_HOME}/.icons \
            ${USER_HOME}/.local/share/applications \
            ${USER_HOME}/.ssh \
            ${USER_HOME}/.gnupg"
    )

    # Добавляем скрытые файлы при необходимости
    if [ "$BACKUP_HIDDEN" -eq 1 ]; then
        BACKUP_SOURCES["home_backup.tar.gz"]+=" ${USER_HOME}/.*"
    fi
}

# ==============================================================================
# СЛУЖЕБНЫЕ ФУНКЦИИ
# ==============================================================================

show_help() {
    echo -e "${GREEN}Использование:${NC} $0 [ОПЦИИ]"
    echo
    echo -e "${BLUE}Опции:${NC}"
    echo "  -o, --output PATH  Каталог для сохранения бэкапов"
    echo "  -h, --help         Показать справку"
    echo "  -c, --config       Показать текущую конфигурацию"
    echo "  --hidden           Включать скрытые файлы"
    echo "  --retain-days N    Хранить резервы N дней (0 - отключить)"
    echo
    echo -e "${BLUE}Примеры:${NC}"
    echo "  sudo $0 --output /mnt/backup --hidden"
    echo "  sudo $0 -o ~/backups --retain-days 14"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        BACKUP_ROOT="$DEFAULT_BACKUP_ROOT"
    fi
}

init_paths() {
    mkdir -p "$BACKUP_DIR"
    
    # Устанавливаем владельца для всей директории рекурсивно
    if command -v chown &>/dev/null; then
        chown -R "${ORIGINAL_USER}:" "$BACKUP_DIR"
    fi
    
    # Создаем лог-файл с правильными правами
    touch "$LOGFILE"
    chmod 600 "$LOGFILE"
    
    # Двойная проверка прав для лог-файла
    if [ "$(stat -c %U "$LOGFILE")" != "$ORIGINAL_USER" ]; then
        chown "${ORIGINAL_USER}:" "$LOGFILE"
    fi
}

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case "$level" in
        "INFO") color="${BLUE}" ;;
        "SUCCESS") color="${GREEN}" ;;
        "WARN") color="${YELLOW}" ;;
        "ERROR") color="${RED}" ;;
    esac
    
    echo -e "[${timestamp}] ${color}${level}${NC}: ${message}" | tee -a "$LOGFILE"
}

check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Требуются права root!"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    local required=("tar" "gzip" "docker" "mysqldump")
    
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log "ERROR" "Отсутствуют зависимости: ${missing[*]}"
        exit 1
    fi
}

# ==============================================================================
# ФУНКЦИИ РЕЗЕРВИРОВАНИЯ
# ==============================================================================

create_archive() {
    local archive_name="$1"
    shift
    local sources=("$@")
    local valid_sources=()
    
    # Включаем скрытые файлы при необходимости
    local tar_options=()
    if [ "$BACKUP_HIDDEN" -eq 1 ]; then
        shopt -s dotglob
        tar_options+=(--wildcards --no-wildcards-match-slash)
    fi

    for path in "${sources[@]}"; do
        if [ -e "$path" ]; then
            if [ -r "$path" ]; then
                valid_sources+=("$path")
            else
                log "WARN" "Нет прав на чтение: $path"
            fi
        else
            log "WARN" "Путь не существует: $path"
        fi
    done

    if [ ${#valid_sources[@]} -eq 0 ]; then
        log "WARN" "Нет данных для архивации: $archive_name"
        return 1
    fi

    log "INFO" "Создание архива: $archive_name"
    if tar -czf "${BACKUP_DIR}/${archive_name}" \
        --warning=no-file-changed \
        --absolute-names \
        --exclude-backups \
        --exclude-vcs \
        --exclude-caches \
        --exclude-vcs-ignores \
        --checkpoint=1000 \
        --checkpoint-action=echo="#%u: %T" \
        --level="$COMPRESSION_LEVEL" \
        "${EXCLUDE_PATTERNS[@]}" \
        "${tar_options[@]}" \
        "${valid_sources[@]}" 2>> "$LOGFILE"
    then
        log "SUCCESS" "Архив создан: $archive_name ($(du -sh "${BACKUP_DIR}/${archive_name}" | cut -f1))"
    else
        local exit_code=$?
        log "ERROR" "Ошибка создания архива (код $exit_code): $archive_name"
        return $exit_code
    fi
}

backup_databases() {
    local db_dir="${BACKUP_DIR}/databases"
    mkdir -p "$db_dir"
    
    # MySQL/MariaDB
    if systemctl is-active --quiet mysqld || systemctl is-active --quiet mariadb; then
        log "INFO" "Резервирование MySQL/MariaDB..."
        if mysqldump --all-databases --single-transaction | gzip > "${db_dir}/mysql_full.sql.gz"; then
            log "SUCCESS" "Дамп MySQL создан"
        else
            log "ERROR" "Ошибка создания дампа MySQL"
        fi
    fi

    # PostgreSQL
    if command -v pg_dumpall &> /dev/null; then
        log "INFO" "Резервирование PostgreSQL..."
        if pg_dumpall | gzip > "${db_dir}/postgres_full.sql.gz"; then
            log "SUCCESS" "Дамп PostgreSQL создан"
        else
            log "ERROR" "Ошибка создания дампа PostgreSQL"
        fi
    fi
}

backup_docker() {
    log "INFO" "Резервирование Docker"
    
    docker ps -a --format "{{.Names}}" > "${BACKUP_DIR}/docker_containers.list"
    docker images --format "{{.Repository}}:{{.Tag}}" > "${BACKUP_DIR}/docker_images.list"
    
    # Резервирование томов
    local volumes=($(docker volume ls -q))
    if [[ ${#volumes[@]} -gt 0 ]]; then
        log "INFO" "Найдено Docker томов: ${#volumes[@]}"
        mkdir -p "${BACKUP_DIR}/docker_volumes"
        for volume in "${volumes[@]}"; do
            log "INFO" "Обработка тома: $volume"
            docker run --rm -v "${volume}:/data" -v "${BACKUP_DIR}/docker_volumes:/backup" \
                alpine tar -czf "/backup/${volume}.tar.gz" -C /data . 2>> "$LOGFILE" &
        done
        wait
    fi
}

cleanup_backups() {
    if [ "$RETAIN_DAYS" -le 0 ]; then
        log "INFO" "Автоматическое удаление старых бэкапов отключено"
        return
    fi

    log "INFO" "Удаление бэкапов старше ${RETAIN_DAYS} дней"
    find "${BACKUP_ROOT}" -maxdepth 1 -name "${BACKUP_PREFIX}_*" -type d -mtime +${RETAIN_DAYS} \
        -exec rm -rfv {} \; | tee -a "$LOGFILE"
}

# ==============================================================================
# ОСНОВНОЙ БЛОК
# ==============================================================================

# Обработка аргументов
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output)
            BACKUP_ROOT="$2"
            shift 2
            ;;
        --hidden)
            BACKUP_HIDDEN=1
            shift
            ;;
        --retain-days)
            RETAIN_DAYS="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--config)
            show_config
            exit 0
            ;;
        *)
            log "ERROR" "Неизвестный аргумент: $1"
            exit 1
            ;;
    esac
done

# Инициализация
check_privileges
load_config
BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_PREFIX}_${CURRENT_DATE}"
LOGFILE="${BACKUP_DIR}/backup.log"
init_paths
init_backup_sources
check_dependencies
ORIGINAL_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")

# Определение дистрибутива
if [ -f /etc/os-release ]; then
    source /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-unknown}"
else
    log "ERROR" "Не удалось определить дистрибутив!"
    exit 2
fi

log "INFO" "Начало резервного копирования"
log "INFO" "• Система: ${DISTRO_ID}-${DISTRO_VERSION}"
log "INFO" "• Каталог: ${BACKUP_DIR}"
log "INFO" "• Сохранять скрытые файлы: $([ "$BACKUP_HIDDEN" -eq 1 ] && echo "Включено" || echo "Отключено")"

# Основной процесс
for archive_name in "${!BACKUP_SOURCES[@]}"; do
    create_archive "$archive_name" ${BACKUP_SOURCES[$archive_name]}
done

backup_databases
backup_docker
cleanup_backups

log "SUCCESS" "Резервное копирование успешно завершено!"
log "INFO" "Итоговый размер: $(du -sh "${BACKUP_DIR}" | cut -f1)"

exit 0
