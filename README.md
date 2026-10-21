# GReSym deploy

Docker Compose окружение **GReSym**: MariaDB, RabbitMQ, Milvus и (по желанию) сами сервисы — API и ML.

Ожидаемая структура каталогов (репозитории рядом):

```text
GReSym/
├── backend/   # ASP.NET API (Dockerfile, manage.sh, config.json)
├── ml/        # ML-сервис (Dockerfile, config.json, Qwen3-Embedding/)
└── deploy/    # этот репозиторий
```

## Сервисы

| Сервис | Профиль | Порт на хосте (только 127.0.0.1) | Данные |
|--------|---------|----------------------------------|--------|
| `mariadb` (11.8) | по умолчанию | 3306 | `data/mariadb` |
| `rabbitmq` (4.2 + management) | по умолчанию | 5672, 15672 | `data/rabbitmq` |
| `milvus` (v3.0.2 standalone, встроенный etcd) | по умолчанию | 19530, 9091 | `data/milvus` |
| `api` (`backend/Dockerfile`) | `app` | 5147 | — |
| `ml-api` (`ml/Dockerfile`) | `app` | 8000 | — |
| `ml-worker` (тот же образ) | `app` | — | — |

Без профиля поднимается только инфраструктура: API и ML можно запускать нативно (`./manage.sh run api`, `uv run ml ...`),
конфиги с `localhost` работают без изменений. Parser UI (GTK) всегда запускается нативно.

Данные хранятся в `data/` (bind mounts, не в git). Файлы в нём принадлежат пользователям контейнеров,
поэтому резервные копии делаются через `manage.sh`, а не копированием каталога.

## Первый запуск

1. Docker без sudo: пользователь в группе `docker`, `docker context use default`, `sudo systemctl enable --now docker`.
2. Заполнить `../backend/config.json` (`../backend/manage.sh setup`) и `../ml/config.json`.
3. (по желанию) положить дамп MariaDB (`*.sql.zst`, `*.sql.gz`, `*.sql`) в `mariadb/seed/`. Он импортируется при первом старте.
4. Запустить:

```bash
./manage.sh setup        # .env из backend/config.json и ml/config.json (+ пароль root MariaDB)
./manage.sh up           # инфраструктура
./manage.sh up --app     # + API, ML API, ML worker (сборка образов)
../backend/manage.sh database update   # применить миграции, если код новее дампа
```

Пользователи MariaDB и RabbitMQ создаются **только при первом запуске** (пустой `data/`).
Пользователь приложения из `backend/config.json` получает все права на базу, пользователь из `ml/config.json` — только чтение.
Изменение паролей в `config.json` позже на них не влияет: меняйте их внутри СУБД (или пересоздайте `data/`).

## Команды

```text
./manage.sh setup                               — сгенерировать .env
./manage.sh up [--app] | down | ps | logs [сервис]
./manage.sh backup [mariadb|milvus|all]         — в backups/<дата>/
./manage.sh restore mariadb <файл> [--yes]
./manage.sh restore milvus <файл.npz> [--yes]
./manage.sh milvus-snapshot [файл]              — точный снимок data/milvus
./manage.sh restore milvus-snapshot <файл> [--yes]
```

### MariaDB

`backup mariadb` / `restore mariadb` вызывают `../backend/manage.sh database dump|restore`. Они подключаются по TCP к опубликованному порту
с учётными данными из `backend/config.json`. Если клиента MariaDB на хосте нет, используется клиент внутри контейнера.

Чтобы заново заполнить базу из дампа: `./manage.sh down`, удалить `data/mariadb`, положить дамп в `mariadb/seed/`, `./manage.sh up`.

### Milvus

- `backup milvus` → `ml export`: логическая копия всех векторов в `.npz`. Не зависит от версии Milvus и подходит для переноса
  на другую машину и для обновления Milvus. Восстановление (`restore milvus`) создаёт коллекцию заново и загружает векторы без модели.
- `milvus-snapshot`: точная копия `data/milvus` (tar.zst). Milvus на время копирования останавливается. Подходит только для той же версии Milvus.

Конфигурация Milvus — `milvus/embedEtcd.yaml` и `milvus/user.yaml` (переопределения `milvus.yaml`). После изменения: `docker compose restart milvus`.

### RabbitMQ

Топологию (`gresym.tasks`, `gresym.dlx`, quorum-очереди `ml.vectorize-game[.dlq]`) объявляют API и ML worker при подключении,
поэтому резервная копия не нужна. Management UI: http://localhost:15672.
