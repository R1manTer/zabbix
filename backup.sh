#!/usr/bin/env bash
# =============================================================================
# Zabbix PostgreSQL Backup Script
# Призначення: pg_dump усередині контейнера → архів → передача на remote
# Особливість: НЕ засмічує локальний диск (tmp файл видаляється після передачі)
#
# Налаштування cron (рекомендовано):
#   0 2 * * * /opt/zabbix_lab/scripts/backup.sh >> /var/log/zabbix_backup.log 2>&1
# =============================================================================

set -euo pipefail

# =============================================================================
# НАЛАШТУВАННЯ — змінити під своє середовище
# =============================================================================

# Директорія проекту
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Завантажуємо .env
source "${PROJECT_DIR}/.env"

# Ім'я контейнера PostgreSQL
PG_CONTAINER="zabbix_postgres"

# Куди зберігати тимчасовий дамп (ЛОКАЛЬНО — видаляється після передачі)
LOCAL_TMP_DIR="/tmp/zabbix_backup"

# Remote сервер (rsync/scp)
REMOTE_USER="backup"
REMOTE_HOST="192.168.1.200"           # ← ЗМІНИТИ на IP backup-сервера
REMOTE_DIR="/backups/zabbix/"
# SSH ключ (рекомендовано замість пароля)
SSH_KEY="/root/.ssh/id_ed25519_backup"

# Скільки останніх бекапів зберігати на remote (0 = не видаляти)
KEEP_REMOTE_BACKUPS=7

# =============================================================================
# ФУНКЦІЇ
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    log "ERROR: $*" >&2
    # Очищення tmp при помилці
    rm -rf "${LOCAL_TMP_DIR}"
    exit 1
}

cleanup() {
    log "Видалення тимчасових файлів..."
    rm -rf "${LOCAL_TMP_DIR}"
}

# =============================================================================
# MAIN
# =============================================================================

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILENAME="zabbix_db_${TIMESTAMP}.sql.gz"
LOCAL_TMP_FILE="${LOCAL_TMP_DIR}/${BACKUP_FILENAME}"

log "======================================================"
log "Запуск резервного копіювання Zabbix PostgreSQL"
log "Контейнер: ${PG_CONTAINER}"
log "База: ${POSTGRES_DB}"
log "======================================================"

# Перевірка: контейнер запущений?
if ! docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
    error_exit "Контейнер ${PG_CONTAINER} не знайдено або не запущений!"
fi

# Створення tmp директорії
mkdir -p "${LOCAL_TMP_DIR}"

# --- Крок 1: pg_dump усередині контейнера ---
log "Виконання pg_dump..."
START_TIME=$(date +%s)

docker exec "${PG_CONTAINER}" \
    pg_dump \
        --username="${POSTGRES_USER}" \
        --dbname="${POSTGRES_DB}" \
        --no-password \
        --format=plain \
        --no-owner \
        --no-acl \
        --compress=0 \
    | gzip -9 > "${LOCAL_TMP_FILE}" \
    || error_exit "pg_dump завершився з помилкою!"

END_TIME=$(date +%s)
DUMP_SIZE=$(du -sh "${LOCAL_TMP_FILE}" | cut -f1)
log "pg_dump завершено за $((END_TIME - START_TIME)) сек. Розмір: ${DUMP_SIZE}"

# --- Крок 2: Передача на remote сервер ---
log "Передача на ${REMOTE_HOST}:${REMOTE_DIR}..."

rsync \
    --archive \
    --compress \
    --progress \
    --rsh="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=30" \
    "${LOCAL_TMP_FILE}" \
    "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}" \
    || error_exit "rsync завершився з помилкою! Файл НЕ передано."

log "Передача успішна!"

# --- Крок 3: Видалення старих бекапів на remote ---
if [[ ${KEEP_REMOTE_BACKUPS} -gt 0 ]]; then
    log "Видалення старих бекапів (залишаємо ${KEEP_REMOTE_BACKUPS} останніх)..."
    ssh \
        -i "${SSH_KEY}" \
        -o StrictHostKeyChecking=no \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "ls -1t ${REMOTE_DIR}zabbix_db_*.sql.gz 2>/dev/null \
         | tail -n +$((KEEP_REMOTE_BACKUPS + 1)) \
         | xargs --no-run-if-empty rm -f \
         && echo 'Старі бекапи видалено.'" \
        || log "WARN: Не вдалося видалити старі бекапи на remote (не критично)"
fi

# --- Крок 4: Видалення локального tmp файлу ---
cleanup
log "Локальний тимчасовий файл видалено. Диск НЕ засмічений."

log "======================================================"
log "BACKUP COMPLETED SUCCESSFULLY: ${BACKUP_FILENAME}"
log "======================================================"
