# Analytics Engineer - тестовое задание

Стартовый репозиторий для тестового задания Analytics Engineer в Highcore.

## Задание

Детали в [TEST_ASSIGNMENT.md](TEST_ASSIGNMENT.md).

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

## Известные особенности датасета (учтено, не тестируется)

Это публичный сэмпл, поэтому ряд свойств отличается от настоящего боевого потока. Зафиксированы здесь, чтобы было ясно, что мы их видим и осознанно не покрываем тестами:

- **Статичный 2018-09-сэмпл** — данные не обновляются. `freshness` на источнике не декларируем; на проде это `freshness: {warn_after: 1 day}` через `loaded_at_field: _LOAD_TIMESTAMP`.
- **Hard-cap 50 000 событий/день** — артефакт публичной выгрузки (114 дней × 50 000 = 5.7M строк). Размеры когорт занижены, абсолютные числа нерепрезентативны — читать только относительно. Не тестируем как инвариант: цифра не изменится сама по себе.
- **207 дублей** по `(user_pseudo_id, event_timestamp, event_name)` (~0.004 %) — известны, дедуплицируются в `stg_events`. На сыром источнике `unique_combination_of_columns` не ставим — упадёт by design.
- **`event_date` (локальный TZ) vs `event_timestamp` (UTC)** — расходятся на 34 % строк. В проекте используем UTC как единый якорь (`event_date_utc = event_timestamp::date`).
- **`user_first_touch_timestamp` врёт у 97 %** пользователей; `first_open` event есть только у 28 %. Поэтому когорта = `min(event_date_utc) per user_pseudo_id`, не `uft` и не `first_open`.

Подробнее — в `docs/data_exploration.md` и `docs/assumptions.md`.

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

