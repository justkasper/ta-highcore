# Analytics Engineer - тестовое задание

Стартовый репозиторий для тестового задания Analytics Engineer в Highcore.

## Требования

- Python 3.11+
- make
- ~2 GB свободного места на диске

## Установка

1. Клонируй репозиторий:

```bash
git clone https://github.com/gerasuchkov/highcore-ae-test-task.git
cd highcore-ae-test-task
```

2. Создай и активируй виртуальное окружение (Python 3.11+):

```bash
python3.11 -m venv .venv
# или python3.12, python3.13 - любая версия 3.11+
source .venv/bin/activate
```

Проверь версию: `python3 --version`. Если `python3` указывает на 3.9 или 3.10, используй явную версию (например `python3.13 -m venv .venv`).

3. Установи зависимости и скачай данные:

```bash
make setup
```

Будут установлены Python-пакеты и скачаны ~500 MB данных с Google Drive.
Первый запуск может занять несколько минут в зависимости от скорости интернета.

Если автоматическое скачивание не сработало, скачай файл вручную и положи в `data/`:
```bash
# Прямая ссылка: https://drive.google.com/file/d/1FTZONE_YydmmewPA3wfysVw8MuUTZe7h/view
# Сохрани как: data/firebase_events.parquet
# Затем повторно запусти:
make setup
```

4. Проверь, что все работает:

```bash
make build
```

Должна пройти компиляция и запуск примера staging-модели без ошибок.

5. (Опционально) dbt docs:

```bash
make docs
```

Сгенерирует и откроет документацию dbt на http://localhost:8080.

## Что внутри

- **DuckDB** - локальная замена BigQuery. SQL-диалект близок, включая работу с nested/struct-полями.
- **dbt-duckdb** - dbt-проект над которым мы будет работать.
- **Данные** - события из мобильной F2P игры (публичный датасет Firebase "firebase-public-project.analytics_153293282").

## Структура репозитория

```
.
├── README.md                 # этот файл
├── TEST_ASSIGNMENT.md        # само задание - начни отсюда
├── Makefile                  # setup / build / docs / clean
├── requirements.txt          # зафиксированные зависимости
├── profiles.yml              # dbt-профиль для DuckDB (локальный)
├── dbt_project.yml           # конфигурация dbt-проекта
├── scripts/
│   └── prepare_data.py       # скачивает данные и загружает в DuckDB
├── data/                     # БД DuckDB и parquet (в gitignore)
├── models/
│   ├── staging/              # staging-модели (views) - пример внутри
│   ├── intermediate/         # intermediate-модели (views)
│   └── marts/                # mart-модели (tables)
├── macros/                   # dbt-макросы
├── tests/                    # кастомные dbt-тесты
├── docs/                     # для документации
└── skills/                   # для скиллов
```

## Задание

Детали в [TEST_ASSIGNMENT.md](TEST_ASSIGNMENT.md).
