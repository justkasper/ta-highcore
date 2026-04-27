# Архитектура dbt-проекта

Документ описывает целевую структуру моделей: какие слои, какие таблицы, на каком грейне, чем материализованы и почему именно так. Продуктовые решения, на которые архитектура опирается, лежат в [`docs/assumptions.md`](assumptions.md); данные, на которых основаны выборы — в [`docs/data_exploration.md`](data_exploration.md).

---

## TL;DR

- **5 слоёв**: `staging` → `intermediate` → `_utils` + `marts/core` → `marts/reports`.
- **Центральный факт** — `fct_user_daily` в `marts/core/` на грейне **user × activity_date** (sparse: только дни с фактом).
- **Дашборд** читает только `marts/reports/*` — headless BI, никакой логики на стороне инструмента.
- **Принцип масштабирования**: всё, что в DuckDB сейчас живёт как view, при росте до BigQuery становится `incremental` table с partition + cluster — переписывать SQL не понадобится, только конфиги.

---

## Принципы дизайна

1. **Headless BI.** Дашборд делает `SELECT * FROM mart_* WHERE filter` — никаких window-функций, JOIN'ов, COUNT DISTINCT на BI-стороне. Любая бизнес-логика приземляется до `marts/reports/`.
2. **Атомарный факт на user-day grain.** В `core` лежит звезда `dim_users + fct_user_daily`. Любой будущий отчёт (когорты, funnels, weekly retention, A/B-разрезы) собирается одним SELECT поверх этой звезды без изменений в нижних слоях.
3. **Sparse факт.** В `fct_user_daily` лежат только дни с фактом — отсутствие строки = «ничего не произошло». Это и семантически правильнее, и дешевле в BigQuery (см. §«Будущая миграция в BigQuery»).
4. **Future-proofing для BQ.** Архитектура одинаково корректна для DuckDB (текущий рантайм) и BigQuery (целевой). Различия инкапсулированы в materialization configs, не в SQL.
5. **Один источник истины для каждого фрагмента бизнес-логики.** Расчёт «что значит активный», «что считается revenue», «что такое cohort_date» — каждый ровно в одном месте.

---

## Слой 1 — `staging/`

**Назначение**: 1:1 с источником, типизация и нормализация. Без фильтрации, без агрегации.

**Материализация**: `view`.

| Модель | Грейн | Что делает |
|---|---|---|
| `stg_events` | 1 row per Firebase event | — типизация: `event_ts_utc = make_timestamp(event_timestamp)`, `event_date_utc = event_ts_utc::date`<br>— dedup: `qualify row_number() over (partition by user_pseudo_id, event_timestamp, event_name) = 1`<br>— распаковка `event_params` в плоские колонки (`engagement_time_msec`, `firebase_screen_class`, `previous_first_open_count`, …)<br>— промоут struct-полей в top-level (`device.category`, `device.operating_system`, `geo.country`, `app_info.id`, `traffic_source.medium`, …)<br>— дроп `user_id` (100 % NULL), `event_dimensions` (100 % NULL), `stream_id` (1:1 с `platform`) |

**Чего не делает**: не считает cohort_date, не фильтрует покупки, не агрегирует — это intermediate/marts.

**Doc-note**: на BigQuery с реальными объёмами `stg_events` переезжает в `materialized=incremental`, partition by `event_date_utc`, unique_key `(user_pseudo_id, event_timestamp, event_name)`. Сейчас view ради простоты на DuckDB (5.7M строк проходят за секунды).

---

## Слой 2 — `intermediate/`

**Назначение**: бизнес-преобразования между staging и marts. Выносит логику расчёта user-grain атрибутов и user-day метрик из mart'ов, чтобы в `core` ехала уже готовая семантика.

**Материализация**: `view` (по умолчанию из `dbt_project.yml`).

| Модель | Грейн | Источник | Что считает |
|---|---|---|---|
| `int_user_install` | 1 row per user | `stg_events` | `cohort_date = min(event_date_utc) per user_pseudo_id`, `install_platform`, `install_country`, `install_country_top5`, `install_traffic_medium`, `install_app_id`, `first_event_name`, `is_reinstall` (по `previous_first_open_count > 0`), `events_total` (для последующего флажка outlier в `dim_users`) |
| `int_user_daily_activity` | 1 row per (user × activity_date) с активностью | `stg_events` | `events`, `engagement_sec` (sum `engagement_time_msec / 1000`), `n_sessions_proxy` (count `event_name = 'session_start'`). **Sparse**: только дни с ≥ 1 event |
| `int_user_daily_revenue` | 1 row per (user × activity_date) с покупкой | `stg_events` filter `event_value_in_usd > 0` | `gross_revenue`, `n_purchases`. **Sparse**: только дни с покупкой |

**Почему три отдельные view, а не одна**:
- `int_user_install` — user-grain (1 row/user); другие — user-day grain.
- `int_user_daily_activity` и `int_user_daily_revenue` имеют **разные источники** в `stg_events`: revenue фильтруется по `event_value_in_usd > 0`, activity — нет. Слить их в одну view = либо доп `LEFT JOIN`, либо `UNION` — лишняя сложность; джойним на стадии `fct_user_daily`.

**Doc-note**: `int_*` — кандидаты на ephemeral/CTE, если хочется ещё уменьшить число объектов в БД. Сейчас view, чтобы можно было читать промежуточные результаты в DuckDB-консоли при отладке.

---

## Слой 3 — `_utils/`

**Назначение**: вспомогательные универсальные сущности, не привязанные к бизнес-логике.

**Материализация**: `view`.

| Модель | Грейн | Что |
|---|---|---|
| `day_numbers` | 1 row per day_number ∈ [0..30] | `SELECT generate_series(0, 30) AS day_number`. Используется в `marts/reports/*` для densification cohort × day решётки |

**Doc-note**: можно реализовать как `seeds/day_numbers.csv`, если макрос/seed ближе по конвенции. Sql-view выбран, потому что 31 строка не стоит отдельного seed-файла.

---

## Слой 4 — `marts/core/` (звезда на user-day grain)

**Назначение**: каноническая звезда. **Не консумится BI напрямую**, только через `reports/*`.

**Материализация**: `table`.

### `dim_users` — user dimension

Грейн: 1 row per `user_pseudo_id`.

Колонки:
- `user_pseudo_id` (PK)
- `cohort_date`
- `install_platform`, `install_country`, `install_country_top5`, `install_traffic_medium`, `install_app_id`
- `first_event_name`
- `is_reinstall` — флажок, продакт может фильтровать
- `is_outlier_events` — флажок (`events_total > p99 ≈ 5 541`); без авто-фильтрации

Зачем выносить отдельно от факта: чистый star-schema. Slowly-changing атрибуты юзера не размазываются по фактам, тесты cohort_size опираются на `dim_users` как на independent source of truth.

### `fct_user_daily` — ★ центральный факт ★

Грейн: 1 row per `(user_pseudo_id × activity_date)` **где у юзера был ≥ 1 event этот день**.

Колонки:
- `user_pseudo_id` (FK → `dim_users`)
- `cohort_date` (денорм из `dim_users` — для удобства фильтра без JOIN)
- `activity_date`
- `day_number = activity_date - cohort_date`
- `events`, `engagement_sec`, `n_sessions_proxy` (из `int_user_daily_activity`)
- `gross_revenue`, `n_purchases`, `paying_flag` (из `int_user_daily_revenue` через `LEFT JOIN`; NULL/0 если в этот день покупок не было)

**Sparse**: строка существует ⇔ юзер был активен в этот день. Колонки `is_active` нет — её роль играет наличие строки. Дни без активности **не материализуются**.

Размер: ~150–200k строк (≈ 15 175 users × ~10–13 активных дней в среднем). Densification до решётки (cohort × day) делается уже в `reports/`.

**Почему именно user-day grain, а не cohort × day × slice (cube)**:
1. Атомарный для F2P-аналитики: «что юзер делал в день X» — это сам факт.
2. Любой будущий отчёт (когорты, funnels, weekly retention, A/B-разрезы) — это `GROUP BY` поверх этой звезды без переделки `core`.
3. Per-user drilldown остаётся возможным, если продакт когда-то попросит.

**Почему sparse, а не dense**:
- На DuckDB разница незначима, но проектируем под BigQuery.
- В BQ on-demand pricing: scan-стоимость считается по байтам с диска. Dense fct содержит ~60 % строк с `is_active = 0` — байты, которые читаются впустую при каждом запросе.
- Sparse + LEFT JOIN с `day_numbers` в reports: densify-JOIN не считается в bytes_scanned (date_spine крошечный), а сэкономленные scan'ы окупают сложность отчёта.
- Семантически чище: «факт» = «что произошло», а не «что мы хотим показать».

---

## Слой 5 — `marts/reports/` (headless BI)

**Назначение**: дашборд-готовые таблицы. Каждая = один SELECT поверх `core` + `_utils/day_numbers`. Дашборд читает `SELECT * FROM mart WHERE filter` — без логики, без window-функций, без COUNT DISTINCT.

**Материализация**: `table`.

| Модель | Грейн | Метрики |
|---|---|---|
| `mart_retention_overall` | 1 row per (cohort_date × day_number) | `cohort_size`, `retained_users`, `retention_pct` |
| `mart_retention_by_platform` | 1 row per (cohort_date × day_number × install_platform) | то же + slice |
| `mart_revenue_overall` | 1 row per (cohort_date × day_number) | `cohort_size`, `paying_users`, `gross_revenue`, `cum_revenue`, `cum_arpu`, `cum_arppu`, `paying_share` |
| `mart_revenue_by_platform` | 1 row per (cohort_date × day_number × install_platform) | то же + slice |

### Шаблон reports под sparse fct

```sql
-- mart_retention_overall.sql
WITH cohorts AS (
    SELECT
        cohort_date,
        COUNT(*) AS cohort_size
    FROM {{ ref('dim_users') }}
    GROUP BY cohort_date
),
grid AS (
    SELECT c.cohort_date, c.cohort_size, d.day_number
    FROM cohorts c
    CROSS JOIN {{ ref('day_numbers') }} d
),
retained AS (
    SELECT
        cohort_date,
        day_number,
        COUNT(DISTINCT user_pseudo_id) AS retained_users
    FROM {{ ref('fct_user_daily') }}
    GROUP BY cohort_date, day_number
)
SELECT
    g.cohort_date,
    g.day_number,
    g.cohort_size,
    COALESCE(r.retained_users, 0) AS retained_users,
    COALESCE(r.retained_users, 0)::FLOAT / g.cohort_size AS retention_pct
FROM grid g
LEFT JOIN retained r USING (cohort_date, day_number)
```

`grid` гарантирует, что в марте будет строка для каждой `(cohort_date, day_number)` пары даже если в эту ячейку никто не дошёл (`retained_users = 0`, `retention_pct = 0`). Дашборд получает полную решётку без NULL-холостого хода.

**Doc-note**: by-country и by-traffic mart'ы — тот же шаблон, не реализованы ради лаконичности тестового. Добавляются за 5 минут копированием шаблона + замена `install_platform` на нужный slice.

---

## Карта моделей

```
models/
├── staging/
│   └── stg_events.sql                   [view]
├── intermediate/
│   ├── int_user_install.sql             [view]
│   ├── int_user_daily_activity.sql      [view]
│   └── int_user_daily_revenue.sql       [view]
├── _utils/
│   └── day_numbers.sql                  [view]
└── marts/
    ├── core/
    │   ├── dim_users.sql                [table]
    │   └── fct_user_daily.sql           [table]   ★ central fact, user × activity_date sparse
    └── reports/
        ├── mart_retention_overall.sql   [table]
        ├── mart_retention_by_platform.sql [table]
        ├── mart_revenue_overall.sql     [table]
        └── mart_revenue_by_platform.sql [table]
```

**Итого 11 моделей**: 1 staging + 3 intermediate + 1 utility + 2 core + 4 reports.

### Граф зависимостей

```
raw.events
   │
   ▼
stg_events ──┬──► int_user_install ──┬──► dim_users ──┬──► mart_retention_overall
             │                       │                ├──► mart_retention_by_platform
             ├──► int_user_daily_activity ──┐         ├──► mart_revenue_overall
             │                              ├──► fct_user_daily ──┘
             └──► int_user_daily_revenue ───┘                ▲
                                                             │
                                              day_numbers ───┴── (densify в reports)
```

---

## Ключевые архитектурные решения с обоснованием

| # | Решение | Альтернатива, которую отвергли | Почему |
|---|---|---|---|
| 1 | `core` на user-day grain (звезда `dim_users + fct_user_daily`) | Cohort × day × slice cube | Атомарный F2P грейн универсален; будущие отчёты добавляются без переделки `core`. |
| 2 | `fct_user_daily` sparse (только дни с фактом) | Dense (cross-product user × 0..30) | Sparse дешевле на BQ on-demand (меньше bytes_scanned); densify в reports не платит за scan. Семантически: факт = «произошло». |
| 3 | Densify в `reports/`, не в `core` | Densify в `core/fct_user_daily` или в `int_*` | Изоляция: `core` остаётся «что произошло», `reports` решают «что показать». При смене max day_number правится одна view (`day_numbers`). |
| 4 | 4 derived mart'а (overall + by_platform на retention/revenue) | Все 8 (включая by_country, by_traffic) или один wide | Демонстрируем pattern, остальные тривиально расширяются. Читать дашборд из 8 узких mart'ов — самый headless вариант. |
| 5 | `staging` = view, без фильтрации | Сразу incremental table | DuckDB+5.7M=миллисекунды. Doc-note про переход на BQ — менять только конфиг, не SQL. |
| 6 | Три отдельные `int_user_daily_*` (activity, revenue) | Одна объединённая | Разные источники в `stg_events` (фильтр по revenue vs всё подряд). Объединение давало бы лишний JOIN/UNION без выигрыша. |
| 7 | `dim_users` отдельно от `fct_user_daily` | Денормализация в факт | Star-schema convention: slowly-changing атрибуты юзера в одном месте; тесты на `cohort_size` через `dim_users` как independent SoT. |
| 8 | `is_active` колонки нет в факте | Колонка `is_active BOOLEAN` | Sparse fct: наличие строки = active. Колонка была бы always TRUE — избыточна. |
| 9 | `_utils/day_numbers` как view | Hardcoded `(0..30)` в каждом отчёте, или seed | View — единственное место для смены окна; не нужен seed-файл ради 31 строки. |

Продуктовые решения (cohort_anchor, окно D30, definition of active, slices, и т.д.) — в [`docs/assumptions.md`](assumptions.md).

---

## Что мы намеренно НЕ строим

- **`fct_user_event`** — отдельный факт на грейне события. Дашборд не требует event-level drill-down; `stg_events` остаётся единственным местом, где живёт грейн «событие».
- **Session-level mart** — `ga_session_id` 100 % пуст в источнике; `session_start` event есть только у 81 % юзеров. Восстановление сессий — отдельная задача с серьёзной погрешностью.
- **Funnel mart по геймплею** (`level_start → level_complete → ...`) — продакт не просил; вне скоупа Part 2.
- **By-country / by-traffic reports** — тот же шаблон, что и `*_by_platform`. Прописываем в README, реализация — копипаст.
- **A/B-разрезы (`firebase_exp_*`)** — не озвучены в брифе. Добавляются как новые колонки в `dim_users` + новый report без изменений в `core`.
- **Прогноз LTV / predicted retention** — это ML-задача, не аналитика.
- **Отдельный cube'ы под retention и revenue** — у них общий грейн фактов (`user × activity_date`); метрики живут в одной таблице.

---

## Будущая миграция в BigQuery

Когда проект уезжает с DuckDB на боевой BQ, меняется только materialization-конфиг — SQL остаётся как есть.

| Слой / модель | DuckDB сейчас | BigQuery target |
|---|---|---|
| `stg_events` | view | `materialized=incremental`, `partition_by=event_date_utc`, `unique_key=(user_pseudo_id, event_timestamp, event_name)`, `incremental_strategy='merge'` |
| `int_*` | view | view (или ephemeral, если DAG разрастётся) |
| `dim_users` | table | table, `cluster_by=user_pseudo_id` |
| `fct_user_daily` | table | table, `partition_by=activity_date`, `cluster_by=(user_pseudo_id, cohort_date)` |
| `mart_*_overall` | table | table, `partition_by=cohort_date` |
| `mart_*_by_platform` | table | table, `partition_by=cohort_date`, `cluster_by=install_platform` |
| `day_numbers` | view | view |

**Что ещё нужно учесть при миграции**:
- DuckDB `make_timestamp(microseconds)` → BQ `TIMESTAMP_MICROS(event_timestamp)`.
- DuckDB `list_filter(event_params, x -> x.key = 'k')[1].value.int_value` → BQ `(SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'k')`.
- DuckDB `qualify` поддерживается в BQ — не требует изменений.
- Macros для извлечения `event_params` (если будем выносить) должны абстрагировать диалект (Jinja-условие на `target.type`).

**Стоимость на BQ-side**: при on-demand pricing основной cost — scan'ы. Sparse `fct_user_daily` + partitioned reports должны держать большинство запросов в пределах одной партиции (~5–10 MB на typical dashboard query).

---

## Тесты и валидация

Сценарии бизнес-инвариантов уже выписаны в [`docs/eda_tests.md`](eda_tests.md). Их размещение по слоям:

- **`_models.yml` в каждом слое**: generic тесты (`unique`, `not_null`, `accepted_values`, `relationships`, `dbt_utils.unique_combination_of_columns`).
- **`tests/` (singular)**: end-to-end сверки (`SUM(gross_revenue) in mart == SUM(event_value_in_usd) in stg`), монотонность кумулятивных метрик, «нет активности до cohort_date».
- **`severity: warn` для drift-watchers**: доля 1-day users, доля `(direct)/(none)` в traffic, размер первого окна когорты — фиксируем baseline, алертим на дрейф.

`packages.yml` будет включать `dbt_utils` для `unique_combination_of_columns`, `expression_is_true`, `equal_rowcount`.

---

## Связанные документы

- [`TEST_ASSIGNMENT.md`](TEST_ASSIGNMENT.md) — оригинальное ТЗ.
- [`docs/data_exploration.md`](data_exploration.md) — числа, аномалии, identifier model.
- [`docs/assumptions.md`](assumptions.md) — продуктовые допущения и mapping «допущение → витрина».
- [`docs/eda_tests.md`](eda_tests.md) — каталог бизнес-инвариантов под тесты.
