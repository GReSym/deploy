#!/bin/bash
#
# Docker-окружение GReSym (compose.yaml). Секреты — в .env, он генерируется из ../backend/config.json и ../ml/config.json.
# Данные контейнеров лежат в data/ (bind mounts), резервные копии — в backups/.

set -o pipefail

cd "$(dirname "$(readlink -f "$0")")" || exit 1
DEPLOY_DIR="$PWD"

ENV_FILE=".env"
BACKEND_CONFIG="../backend/config.json"
ML_CONFIG="../ml/config.json"
BACKUPS_DIR="backups"
DATA_DIRS=("data/mariadb" "data/rabbitmq" "data/milvus")
PLACEHOLDERS=("" "null" "xxx" "###")
MILVUS_IMAGE="milvusdb/milvus:v3.0.2"

command -v docker >/dev/null || { echo "docker не установлен"; exit 1; }
command -v jq >/dev/null || { echo "jq не установлен"; exit 1; }

# Индексы PyTorch для TORCH_BACKEND (сборка образа ML). cpu берётся из uv.lock (индекс pytorch-cpu в ml/pyproject.toml)
declare -A TORCH_INDEXES=(
    [rocm]="https://download.pytorch.org/whl/rocm7.14"
    [cuda]="https://download.pytorch.org/whl/cu132"
)

# docker compose с GPU-оверлеем для TORCH_BACKEND=rocm|cuda (compose.rocm.yaml / compose.cuda.yaml).
# Явный -f отключает автозагрузку compose.override.yaml, поэтому он добавляется вручную
compose() {
    local files=(-f compose.yaml)
    local backend
    backend=$(env_value TORCH_BACKEND)
    if [[ -n "$backend" && "$backend" != "cpu" ]]; then
        files+=(-f "compose.$backend.yaml")
    fi
    [[ -f compose.override.yaml ]] && files+=(-f compose.override.yaml)
    docker compose "${files[@]}" "$@"
}

is_placeholder() {
    local value="$1"
    for p in "${PLACEHOLDERS[@]}"; do
        [[ "$value" == "$p" ]] && return 0
    done
    return 1
}

require_docker() {
    if ! docker info >/dev/null 2>&1; then
        echo "Ошибка: нет доступа к Docker daemon."
        echo "Проверьте: sudo systemctl start docker, членство в группе docker (нужен перелогин), docker context use default"
        exit 1
    fi
}

require_env() {
    [[ -f "$ENV_FILE" ]] || { echo "Ошибка: $ENV_FILE не найден. Выполните ./manage.sh setup"; exit 1; }
}

# Значение из .env (формат KEY='value')
env_value() {
    [[ -f "$ENV_FILE" ]] || return 0
    sed -n "s/^$1='\(.*\)'\$/\1/p" "$ENV_FILE" | tail -n 1
}

# Значения с ; " ' = или пробелами по краям оборачиваются в кавычки (как в backend/manage.sh)
quote_conn_value() {
    local value="$1"
    if [[ "$value" =~ [\;\"\'=] || "$value" != "${value#[[:space:]]}" || "$value" != "${value%[[:space:]]}" ]]; then
        printf '"%s"' "${value//\"/\"\"}"
    else
        printf '%s' "$value"
    fi
}

setup() {
    [[ -f "$BACKEND_CONFIG" ]] || { echo "Ошибка: $BACKEND_CONFIG не найден (../backend/manage.sh setup)"; exit 1; }
    [[ -f "$ML_CONFIG" ]] || { echo "Ошибка: $ML_CONFIG не найден (см. ../ml/config.example.json)"; exit 1; }

    local -A values
    values[DB_NAME]=$(jq -r '.database // empty' "$BACKEND_CONFIG")
    values[DB_PORT]=$(jq -r '.port // empty' "$BACKEND_CONFIG")
    values[DB_USER]=$(jq -r '.user // empty' "$BACKEND_CONFIG")
    values[DB_PASSWORD]=$(jq -r '.password // empty' "$BACKEND_CONFIG")
    values[RABBITMQ_USER]=$(jq -r '.rabbitmq_user // empty' "$BACKEND_CONFIG")
    values[RABBITMQ_PASSWORD]=$(jq -r '.rabbitmq_password // empty' "$BACKEND_CONFIG")
    values[JWT_KEY]=$(jq -r '.jwt_key // empty' "$BACKEND_CONFIG")
    values[JWT_EXPIRE_MINUTES]=$(jq -r '.jwt_expire_minutes // 60' "$BACKEND_CONFIG")
    values[DB_READONLY_USER]=$(jq -r '.database.user // empty' "$ML_CONFIG")
    values[DB_READONLY_PASSWORD]=$(jq -r '.database.password // empty' "$ML_CONFIG")

    # Пароль root генерируется один раз: MariaDB применяет его только при первой инициализации data/mariadb
    values[MARIADB_ROOT_PASSWORD]=$(env_value MARIADB_ROOT_PASSWORD)
    if is_placeholder "${values[MARIADB_ROOT_PASSWORD]}"; then
        command -v openssl >/dev/null || { echo "openssl не установлен"; exit 1; }
        values[MARIADB_ROOT_PASSWORD]=$(openssl rand -hex 24)
        echo "Сгенерирован пароль root для MariaDB"
    fi

    local missing=() key
    for key in DB_NAME DB_PORT DB_USER DB_PASSWORD RABBITMQ_USER RABBITMQ_PASSWORD JWT_KEY DB_READONLY_USER DB_READONLY_PASSWORD; do
        is_placeholder "${values[$key]}" && missing+=("$key")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Ошибка: не заполнены параметры: ${missing[*]} (JWT_KEY создаёт ../backend/manage.sh setup)"
        exit 1
    fi
    if [[ "${values[DB_PORT]}" != "3306" ]]; then
        echo "Внимание: port в $BACKEND_CONFIG = ${values[DB_PORT]}, контейнер MariaDB будет опубликован на этом порту"
    fi

    # Сборка PyTorch: TORCH_BACKEND=rocm ./manage.sh setup, иначе остаётся значение из .env (по умолчанию cpu)
    values[TORCH_BACKEND]="${TORCH_BACKEND:-$(env_value TORCH_BACKEND)}"
    values[TORCH_BACKEND]="${values[TORCH_BACKEND]:-cpu}"
    case "${values[TORCH_BACKEND]}" in
        cpu|rocm|cuda) ;;
        *) echo "Ошибка: TORCH_BACKEND=${values[TORCH_BACKEND]}, ожидается cpu, rocm или cuda"; exit 1 ;;
    esac
    # Индекс можно переопределить (TORCH_INDEX_URL=... ./manage.sh setup), пока backend не меняется
    local previous_backend
    previous_backend=$(env_value TORCH_BACKEND)
    values[TORCH_INDEX_URL]="${TORCH_INDEX_URL:-}"
    if [[ -z "${values[TORCH_INDEX_URL]}" && "$previous_backend" == "${values[TORCH_BACKEND]}" ]]; then
        values[TORCH_INDEX_URL]=$(env_value TORCH_INDEX_URL)
    fi
    [[ "${values[TORCH_BACKEND]}" == "cpu" ]] && values[TORCH_INDEX_URL]=""
    [[ "${values[TORCH_BACKEND]}" != "cpu" && -z "${values[TORCH_INDEX_URL]}" ]] && values[TORCH_INDEX_URL]="${TORCH_INDEXES[${values[TORCH_BACKEND]}]}"
    values[ML_MODEL_DTYPE]="${ML_MODEL_DTYPE:-$(env_value ML_MODEL_DTYPE)}"
    values[ML_MODEL_DTYPE]="${values[ML_MODEL_DTYPE]:-bfloat16}"
    # ROCm: контейнеру нужны группы video и render хоста (доступ к /dev/kfd и /dev/dri)
    values[VIDEO_GID]=$(getent group video | cut -d: -f3)
    values[RENDER_GID]=$(getent group render | cut -d: -f3)
    if [[ "${values[TORCH_BACKEND]}" == "rocm" ]]; then
        if [[ -z "${values[VIDEO_GID]}" || -z "${values[RENDER_GID]}" ]]; then
            echo "Ошибка: на хосте нет группы video или render (нужны для ROCm)"
            exit 1
        fi
        [[ -e /dev/kfd ]] || echo "Внимание: /dev/kfd не найден, драйвер amdgpu не загружен?"
    fi
    if [[ "${values[TORCH_BACKEND]}" != "$previous_backend" && -n "$previous_backend" ]]; then
        echo "TORCH_BACKEND: $previous_backend → ${values[TORCH_BACKEND]}. Пересоберите образ ML: ./manage.sh up --app"
    fi
    echo "PyTorch: ${values[TORCH_BACKEND]}${values[TORCH_INDEX_URL]:+ (${values[TORCH_INDEX_URL]})}"

    values[API_DB_CONNECTION]="Server=mariadb;Port=3306;Database=${values[DB_NAME]};User=$(quote_conn_value "${values[DB_USER]}");Password=$(quote_conn_value "${values[DB_PASSWORD]}");"

    local order=(MARIADB_ROOT_PASSWORD DB_NAME DB_PORT DB_USER DB_PASSWORD DB_READONLY_USER DB_READONLY_PASSWORD
                 RABBITMQ_USER RABBITMQ_PASSWORD JWT_KEY JWT_EXPIRE_MINUTES API_DB_CONNECTION
                 TORCH_BACKEND TORCH_INDEX_URL ML_MODEL_DTYPE VIDEO_GID RENDER_GID)
    for key in "${order[@]}"; do
        if [[ "${values[$key]}" == *"'"* || "${values[$key]}" == *$'\n'* ]]; then
            echo "Ошибка: значение $key содержит одинарную кавычку или перевод строки, в .env так нельзя"
            exit 1
        fi
    done

    local tmp
    tmp=$(mktemp)
    chmod 600 "$tmp"
    {
        echo "# Сгенерирован ./manage.sh setup из $BACKEND_CONFIG и $ML_CONFIG. Не коммитить."
        for key in "${order[@]}"; do
            printf "%s='%s'\n" "$key" "${values[$key]}"
        done
    } > "$tmp" && mv "$tmp" "$ENV_FILE"
    echo "Файл $ENV_FILE обновлён"
    echo "Учётные записи MariaDB/RabbitMQ создаются только при первом запуске (пустой data/). Позже их меняют внутри СУБД."
}

prepare_dirs() {
    mkdir -p "${DATA_DIRS[@]}" "$BACKUPS_DIR"
}

up() {
    require_docker
    require_env
    prepare_dirs
    local args=()
    [[ "$1" == "--app" ]] && args+=(--profile app)
    if [[ ! -e data/mariadb/mysql ]]; then
        local seed
        seed=$(ls -1t mariadb/seed/*.sql mariadb/seed/*.sql.gz mariadb/seed/*.sql.xz mariadb/seed/*.sql.zst 2>/dev/null | head -n 1)
        if [[ -n "$seed" ]]; then
            echo "data/mariadb пуст: при первом запуске будет импортирован $seed (несколько минут)"
        else
            echo "data/mariadb пуст и в mariadb/seed/ нет дампа: база будет создана пустой"
        fi
    fi
    compose "${args[@]}" up -d --build --wait
}

down() {
    require_docker
    compose --profile app down
}

backup_mariadb() {
    local dir="$1"
    local db_name
    db_name=$(env_value DB_NAME)
    local ext="sql.gz"
    command -v zstd >/dev/null && ext="sql.zst"
    ../backend/manage.sh database dump "$DEPLOY_DIR/$dir/mariadb-${db_name:-GamesRecommend}.$ext"
}

# Команды ml запускаются нативно через uv (Milvus опубликован на localhost), без uv — в контейнере ml-api
run_ml() {
    if command -v uv >/dev/null && [[ -f "$ML_CONFIG" ]]; then
        (cd ../ml && uv run ml "$@")
    else
        require_docker
        require_env
        compose --profile app run --rm --no-deps -T ml-api ml "$@"
    fi
}

# Путь к файлу для run_ml: нативно — абсолютный, в контейнере — внутри /backups
ml_path() {
    local path
    path=$(readlink -f "$1")
    if command -v uv >/dev/null && [[ -f "$ML_CONFIG" ]]; then
        echo "$path"
    elif [[ "$path" == "$DEPLOY_DIR/$BACKUPS_DIR/"* ]]; then
        echo "/backups/${path#"$DEPLOY_DIR/$BACKUPS_DIR/"}"
    else
        echo "Ошибка: без uv файл должен лежать в $BACKUPS_DIR/" >&2
        return 1
    fi
}

backup_milvus() {
    local dir="$1"
    local target
    target=$(ml_path "$dir/milvus.npz") || exit 1
    run_ml export --out "$target"
}

backup() {
    local what="${1:-all}"
    local dir
    dir="$BACKUPS_DIR/$(date +%Y%m%dT%H%M)"
    mkdir -p "$dir"
    case "$what" in
        mariadb) backup_mariadb "$dir" || exit 1 ;;
        milvus) backup_milvus "$dir" || exit 1 ;;
        all)
            backup_mariadb "$dir" || exit 1
            # Коллекции может ещё не быть (векторы не построены): это не повод терять дамп MariaDB
            backup_milvus "$dir" || echo "Внимание: векторы Milvus не сохранены (см. сообщение выше)"
            ;;
        *) echo "Использование: ./manage.sh backup [mariadb|milvus|all]"; exit 1 ;;
    esac
    echo "Резервная копия: $dir"
}

restore() {
    local what="$1" file="$2" assume_yes="$3"
    [[ -n "$file" ]] || { echo "Использование: ./manage.sh restore {mariadb|milvus|milvus-snapshot} <файл> [--yes]"; exit 1; }
    [[ -f "$file" ]] || { echo "Ошибка: файл $file не найден"; exit 1; }
    case "$what" in
        mariadb)
            ../backend/manage.sh database restore "$(readlink -f "$file")" "$assume_yes"
            ;;
        milvus)
            local source args=()
            source=$(ml_path "$file") || exit 1
            [[ "$assume_yes" == "--yes" ]] && args+=(--yes)
            run_ml import "$source" "${args[@]}"
            ;;
        milvus-snapshot)
            milvus_snapshot_restore "$file" "$assume_yes"
            ;;
        *)
            echo "Использование: ./manage.sh restore {mariadb|milvus|milvus-snapshot} <файл> [--yes]"
            exit 1
            ;;
    esac
}

# Точная копия data/milvus (только для той же версии Milvus). Milvus на время копирования останавливается.
# Файлы принадлежат пользователю контейнера, поэтому tar запускается внутри образа Milvus от root
milvus_snapshot() {
    require_docker
    command -v zstd >/dev/null || { echo "zstd не установлен"; exit 1; }
    local target="${1:-$BACKUPS_DIR/milvus-snapshot-$(date +%Y%m%dT%H%M).tar.zst}"
    [[ -e "$target" ]] && { echo "Ошибка: $target уже существует"; exit 1; }
    mkdir -p "$(dirname "$target")"
    echo "Останавливаем Milvus"
    compose stop milvus || exit 1
    echo "Снимок data/milvus → $target"
    if docker run --rm --user 0:0 --network none --entrypoint tar \
            -v "$DEPLOY_DIR/data/milvus:/src:ro" "$MILVUS_IMAGE" \
            --numeric-owner -C /src -cf - . | zstd -q -T0 -10 > "$target"; then
        echo "Готово: $target ($(du -h "$target" | cut -f1))"
    else
        rm -f "$target"
        echo "Ошибка при создании снимка"
    fi
    echo "Запускаем Milvus"
    compose up -d --wait milvus
}

milvus_snapshot_restore() {
    local file="$1" assume_yes="$2"
    require_docker
    command -v zstd >/dev/null || { echo "zstd не установлен"; exit 1; }
    if [[ "$assume_yes" != "--yes" ]]; then
        echo "Текущее содержимое data/milvus будет удалено и заменено снимком $file."
        read -r -p "Продолжить? [y/N] " answer
        [[ "$answer" =~ ^[YyДд]$ ]] || { echo "Отменено"; exit 1; }
    fi
    prepare_dirs
    echo "Останавливаем Milvus"
    compose stop milvus || exit 1
    if zstd -q -dc "$file" | docker run --rm -i --user 0:0 --network none --entrypoint /bin/sh \
            -v "$DEPLOY_DIR/data/milvus:/dst" "$MILVUS_IMAGE" \
            -c 'find /dst -mindepth 1 -delete && tar --numeric-owner -C /dst -xpf -'; then
        echo "Снимок восстановлен"
    else
        echo "Ошибка при восстановлении снимка"
        exit 1
    fi
    compose up -d --wait milvus
}

case "${1:-}" in
    setup) setup ;;
    up) up "${2:-}" ;;
    down) down ;;
    ps) require_docker; compose --profile app ps ;;
    logs) require_docker; shift; compose --profile app logs -f --tail 200 "$@" ;;
    backup) backup "${2:-all}" ;;
    restore) restore "${2:-}" "${3:-}" "${4:-}" ;;
    milvus-snapshot) milvus_snapshot "${2:-}" ;;
    *)
        echo "Использование: $0 {setup|up|down|ps|logs|backup|restore|milvus-snapshot}"
        echo "  setup                       — сгенерировать .env из ../backend/config.json и ../ml/config.json"
        echo "                                (TORCH_BACKEND=cpu|rocm|cuda ./manage.sh setup — сборка PyTorch для ML)"
        echo "  up [--app]                  — запустить MariaDB, RabbitMQ, Milvus (--app: ещё API, ML API, ML worker)"
        echo "  down                        — остановить и удалить контейнеры (данные в data/ остаются)"
        echo "  ps | logs [сервис]          — состояние / логи"
        echo "  backup [mariadb|milvus|all] — резервная копия в backups/<дата>/ (по умолчанию all)"
        echo "  restore mariadb <файл> [--yes]          — восстановить MariaDB из дампа"
        echo "  restore milvus <файл.npz> [--yes]       — восстановить векторы из ml export"
        echo "  restore milvus-snapshot <файл> [--yes]  — вернуть снимок data/milvus"
        echo "  milvus-snapshot [файл]      — точный снимок data/milvus (Milvus останавливается на время копирования)"
        exit 1
        ;;
esac
