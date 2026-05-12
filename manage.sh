#!/usr/bin/env bash
# =============================================================================
# Zabbix Stack — Утиліти обслуговування
# Використання: ./scripts/manage.sh [команда]
# =============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="docker compose --project-directory ${PROJECT_DIR}"

# Кольори для виводу
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_title() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# =============================================================================

cmd_status() {
    log_title "Статус Zabbix Stack"
    ${COMPOSE} ps
    echo ""
    log_info "Використання ресурсів:"
    docker stats --no-stream \
        zabbix_postgres zabbix_server zabbix_web 2>/dev/null \
        || log_warn "Деякі контейнери не запущені"
}

cmd_start() {
    log_title "Запуск Zabbix Stack"
    cd "${PROJECT_DIR}"
    docker compose up -d
    log_info "Очікування ініціалізації (60 сек)..."
    sleep 10
    cmd_status
}

cmd_stop() {
    log_title "Зупинка Zabbix Stack"
    cd "${PROJECT_DIR}"
    docker compose stop
    log_info "Stack зупинено (дані збережені)"
}

cmd_restart() {
    log_title "Перезапуск Zabbix Stack"
    cmd_stop
    sleep 3
    cmd_start
}

cmd_logs() {
    local service="${2:-}"
    if [[ -n "${service}" ]]; then
        ${COMPOSE} logs -f --tail=100 "${service}"
    else
        ${COMPOSE} logs -f --tail=50
    fi
}

cmd_db_size() {
    log_title "Розмір бази даних Zabbix"
    docker exec zabbix_postgres psql \
        -U "${POSTGRES_USER:-zabbix}" \
        -d "${POSTGRES_DB:-zabbix}" \
        -c "
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS data_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;
" 2>/dev/null || log_error "Не вдалося підключитися до БД"

    docker exec zabbix_postgres psql \
        -U "${POSTGRES_USER:-zabbix}" \
        -d "${POSTGRES_DB:-zabbix}" \
        -c "SELECT pg_size_pretty(pg_database_size('${POSTGRES_DB:-zabbix}')) AS db_total_size;" \
        2>/dev/null
}

cmd_housekeeping_status() {
    log_title "Статус Housekeeping (останні 24 год)"
    docker exec zabbix_postgres psql \
        -U "${POSTGRES_USER:-zabbix}" \
        -d "${POSTGRES_DB:-zabbix}" \
        -c "
SELECT
    to_timestamp(clock) AT TIME ZONE 'Europe/Kiev' AS time,
    value_str AS message
FROM history_text ht
JOIN items i ON i.itemid = ht.itemid
JOIN hosts h ON h.hostid = i.hostid
WHERE h.host = 'Zabbix server'
  AND i.key_ LIKE '%housekeeper%'
  AND clock > extract(epoch FROM now()) - 86400
ORDER BY clock DESC
LIMIT 10;
" 2>/dev/null || log_warn "Таблиця history_text недоступна або порожня"
}

cmd_disk_check() {
    log_title "Дисковий простір"
    log_info "Розмір ./db_data:"
    du -sh "${PROJECT_DIR}/db_data" 2>/dev/null || log_warn "Директорія db_data не знайдена"

    log_info "Загальне використання диску:"
    df -h "${PROJECT_DIR}"

    log_info "Docker образи Zabbix:"
    docker images | grep -E "zabbix|postgres" || true
}

cmd_pingers_check() {
    log_title "Перевірка процесів Zabbix Server"
    docker exec zabbix_server \
        zabbix_server --version 2>/dev/null | head -1 || true

    log_info "Активні pinger процеси:"
    docker exec zabbix_server \
        ps aux | grep -c "[p]inger" 2>/dev/null \
        && echo "pinger процесів знайдено" \
        || log_warn "Не вдалося перевірити pinger процеси"
}

cmd_migrate_help() {
    log_title "Інструкція переїзду на новий сервер"
    cat << 'EOF'

  1. На СТАРОМУ сервері:
     ./scripts/backup.sh           # Зробити бекап БД

  2. Скопіювати весь проект:
     rsync -avz /opt/zabbix_lab/ user@NEW_SERVER:/opt/zabbix_lab/

  3. На НОВОМУ сервері:
     cd /opt/zabbix_lab
     docker compose up -d          # Запуск (БД вже в ./db_data)

  ✓ Весь стан зберігається в ./db_data (PostgreSQL data directory)
  ✓ Жодних named volumes — тільки bind mounts
  ✓ Переїзд = копіювання папки + docker compose up -d

EOF
}

# =============================================================================
# ENTRYPOINT
# =============================================================================

# Завантажуємо .env якщо є
[[ -f "${PROJECT_DIR}/.env" ]] && source "${PROJECT_DIR}/.env"

case "${1:-help}" in
    start)           cmd_start ;;
    stop)            cmd_stop ;;
    restart)         cmd_restart ;;
    status)          cmd_status ;;
    logs)            cmd_logs "$@" ;;
    db-size)         cmd_db_size ;;
    hk-status)       cmd_housekeeping_status ;;
    disk)            cmd_disk_check ;;
    pingers)         cmd_pingers_check ;;
    migrate)         cmd_migrate_help ;;
    *)
        echo ""
        echo "  Використання: $0 [команда]"
        echo ""
        echo "  Команди:"
        echo "    start       — Запустити stack"
        echo "    stop        — Зупинити stack"
        echo "    restart     — Перезапустити stack"
        echo "    status      — Статус і ресурси"
        echo "    logs [svc]  — Логи (zabbix-server|zabbix-web|postgres)"
        echo "    db-size     — Розмір таблиць БД"
        echo "    hk-status   — Статус Housekeeping"
        echo "    disk        — Дисковий простір"
        echo "    pingers     — Перевірка pinger процесів"
        echo "    migrate     — Інструкція переїзду"
        echo ""
        ;;
esac
