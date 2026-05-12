# Zabbix 7.0 LTS — Docker Compose V2
## Масштабований моніторинг 500+ пристроїв | RAID 5 | ICMP High-Frequency

---

## Структура проекту

```
zabbix_lab/
├── .env                          ← Усі змінні середовища
├── docker-compose.yml            ← Специфікація стека
├── db_data/                      ← Дані PostgreSQL (auto-created)
├── postgres_conf/
│   └── zbx_tuning.conf           ← PostgreSQL tuning (25% RAM)
├── scripts/
│   ├── backup.sh                 ← Резервне копіювання → remote
│   └── manage.sh                 ← Утиліти обслуговування
├── zbx_alertscripts/             ← Кастомні alert scripts
└── zbx_externalscripts/          ← External check scripts
```

---

## Швидкий старт

### 1. Підготовка

```bash
# Клонувати або скопіювати проект
cp -r zabbix_lab/ /opt/zabbix_lab/
cd /opt/zabbix_lab

# Зробити скрипти виконуваними
chmod +x scripts/*.sh

# Створити необхідні директорії
mkdir -p db_data zbx_alertscripts zbx_externalscripts
```

### 2. Налаштування

```bash
# ОБОВ'ЯЗКОВО змінити пароль БД!
nano .env
# Знайти: POSTGRES_PASSWORD=CHANGE_ME_STRONG_PASSWORD_123!
# Замінити на надійний пароль
```

### 3. Запуск

```bash
docker compose up -d

# Перевірити статус
./scripts/manage.sh status

# Переглянути логи ініціалізації
docker compose logs -f zabbix-server
```

### 4. Доступ до Web UI

```
URL:      http://YOUR_SERVER_IP:8080
Login:    Admin
Password: zabbix
```

> ⚠️ Змінити пароль Admin одразу після першого входу!

---

## Конфігурація для 500+ хостів

### ICMP Pinger

В `.env` встановлено `ZBX_STARTPINGERS=40` — це 40 паралельних процесів для ICMP-перевірок.

**Рекомендовані інтервали перевірки:**

| Тип вузла | Інтервал | Кількість спроб |
|-----------|----------|-----------------|
| Критичні (шлюзи, ядро) | 5 сек | 3 |
| Важливі (сервери, SW L3) | 15 сек | 3 |
| Стандартні (PC, принтери) | 60 сек | 2 |

**Налаштування в Zabbix Web UI:**
```
Configuration → Hosts → вибрати хост →
Templates → ICMP Ping → Macros:
  {$ICMP_RESPONSE_TIME.WARN} = 50
  {$ICMP_LOSS.WARN} = 20
```

### Housekeeping (критично для RAID 5, 72-140 GB)

Налаштувати в **Administration → General → Housekeeping**:

| Параметр | Значення | Причина |
|----------|----------|---------|
| History | **7 днів** | Обмеження розміру на RAID 5 |
| Trends | **365 днів** | Тренди малі, цінні для аналізу |
| Events | **30 днів** | Достатньо для аудиту |
| Trigger data | **3 дні** | Оперативні дані |

> **Розрахунок:** 500 хостів × 5 items/хост × 15 сек = ~166 записів/сек.
> За 7 днів = ~100 млн рядків в history. При ~50 байт/рядок ≈ 5 GB history.
> Тренди значно менші: 1 запис/год замість 240 записів/год.

---

## PostgreSQL Tuning

Файл `postgres_conf/zbx_tuning.conf` автоматично підключається.

**Ключові параметри для системи 16 GB RAM:**

| Параметр | Значення | Пояснення |
|----------|----------|-----------|
| `shared_buffers` | 1 GB | 25% від ліміту контейнера (4 GB) |
| `effective_cache_size` | 3 GB | Підказка планувальнику |
| `work_mem` | 16 MB | На з'єднання (100 conn × 16 MB) |
| `checkpoint_completion_target` | 0.9 | Розмазати I/O checkpoint по часу |
| `random_page_cost` | 2.0 | Оптимізовано для SAS RAID |
| `autovacuum_naptime` | 30s | Агресивний autovacuum для Zabbix |

---

## Резервне копіювання

```bash
# Налаштувати remote сервер у scripts/backup.sh:
REMOTE_HOST="192.168.1.200"  # IP backup-сервера
REMOTE_USER="backup"
REMOTE_DIR="/backups/zabbix/"
SSH_KEY="/root/.ssh/id_ed25519_backup"

# Генерувати SSH ключ (якщо немає):
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_backup -N ""
ssh-copy-id -i /root/.ssh/id_ed25519_backup.pub backup@192.168.1.200

# Тест backup:
./scripts/backup.sh

# Додати в cron (щоденно о 02:00):
echo "0 2 * * * root /opt/zabbix_lab/scripts/backup.sh >> /var/log/zabbix_backup.log 2>&1" \
  >> /etc/cron.d/zabbix-backup
```

**Особливість скрипту:** тимчасовий файл дампу автоматично видаляється після передачі — локальний диск не засмічується.

---

## Переїзд на новий сервер

```bash
# 1. Зробити бекап БД на старому сервері
/opt/zabbix_lab/scripts/backup.sh

# 2. Скопіювати весь проект (включно з db_data/)
rsync -avz --progress /opt/zabbix_lab/ user@NEW_SERVER:/opt/zabbix_lab/

# 3. На новому сервері
cd /opt/zabbix_lab
docker compose up -d

# Готово! Весь стан зберігається в ./db_data
```

> **Принцип:** весь проект в одній директорії. Жодних named Docker volumes.
> Переїзд = rsync папки + `docker compose up -d`.

---

## Корисні команди

```bash
# Управління стеком
./scripts/manage.sh start|stop|restart|status

# Логи в реальному часі
./scripts/manage.sh logs zabbix-server
./scripts/manage.sh logs postgres

# Розмір БД та таблиць
./scripts/manage.sh db-size

# Перевірка дискового простору
./scripts/manage.sh disk

# Прямий доступ до psql
docker exec -it zabbix_postgres psql -U zabbix -d zabbix

# Перевірка pinger процесів
docker exec zabbix_server ps aux | grep pinger | wc -l
```

---

## Версії компонентів

| Компонент | Образ |
|-----------|-------|
| Zabbix Server | `zabbix/zabbix-server-pgsql:alpine-7.0-latest` |
| Zabbix Web | `zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest` |
| PostgreSQL | `postgres:15-alpine` |

---

## Відомі нюанси

1. **ICMP без root:** `sysctls: net.ipv4.ping_group_range: "0 2147483647"` у compose-файлі дозволяє pinger процесам надсилати ICMP без привілейованого режиму.

2. **Перший запуск:** Zabbix Server при першому запуску виконує міграцію схеми БД (~2-5 хвилин). Це нормально — стежте за `docker compose logs -f zabbix-server`.

3. **RAID 5 та fsync:** PostgreSQL за замовчуванням використовує `fsync=on` — це правильно для цілісності даних навіть на RAID з кешем запису.

4. **Ліміти пам'яті:** `deploy.resources.limits` у Compose V2 застосовуються тільки при використанні `docker compose` (не `docker stack deploy`).
