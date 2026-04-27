# Highcore - Analytics Engineer test assignment

Тестовое задание: на сыром потоке Firebase-событий публичного F2P-датасета собрать dbt-проект и ответить продакту на вопрос «как ведут себя новые игроки в первые дни» (retention и монетизация по когортам) витриной, из которой дашборд собирается тривиально.

Стек: **DuckDB + dbt-duckdb** локально (как замена BigQuery), Python 3.11+ для подготовки данных, matplotlib для рендера мокапов дашборда. На проде архитектура без переписывания SQL ложится на BigQuery, отличается только конфиг материализаций (см. [`docs/decisions/architecture.md`](docs/decisions/architecture.md) §6 «Будущая миграция в BigQuery»).

Полный текст ТЗ в [`TEST_ASSIGNMENT.md`](TEST_ASSIGNMENT.md).

> ⚠ **Note for reviewer.** В рабочем процессе каждая часть ТЗ разрабатывалась в своей `feature/part-N-*` ветке; артефакты распределены так:
>
> - `feature/part-1-data-exploration`: `docs/data_exploration.md`, `models/staging/_raw_events__eda.md` (doc block для `raw.events`, рендерится в `dbt docs`), `duckdb-explore.sh`
> - `feature/part-2-product-framing`: продуктовые допущения зафиксированы в §3 этого файла
> - `feature/part-3-architecture-doc`: `models/`, `tests/`, `docs/decisions/architecture.md`, `docs/decisions/testing-strategy.md`
> - `feature/part-4-dashboard-sketch`: `docs/dashboard_sketch.md`, `docs/img/dashboard/`, `scripts/render_dashboard_mocks.py`, perf-фиксы (`profiles.yml`, hash-aggregate dedup), shared macros
>
> Этот README описывает **итоговое merged-состояние** - все ссылки предполагают, что ветки слиты в `main`. До слияния часть ссылок вида `docs/<file>.md` будет 404 на отдельных feature-ветках.

---

## 1. Как запустить

**Требования:** Python 3.11+, `make`, ~2 GB на диске, ≥ 8 GB RAM (см. §«Известные ограничения», на меньшем cold-rebuild `stg_events` не помещается в один CTAS).

```bash
git clone https://github.com/gerasuchkov/highcore-ae-test-task
cd highcore-ae-test-task

# 1. venv (Python 3.11+ строго; 3.9/3.10 не подойдут)
python3.11 -m venv .venv
source .venv/bin/activate

# 2. зависимости + ~500 MB данных с Google Drive
make setup

# 3. полный прогон (compile, seed, run, test)
make build

# 4. (опционально) интерактивный dbt docs на http://localhost:8080
make docs
```

Если автоматическое скачивание данных упало, положи parquet вручную: прямая ссылка [firebase_events.parquet](https://drive.google.com/file/d/1FTZONE_YydmmewPA3wfysVw8MuUTZe7h/view), сохрани как `data/firebase_events.parquet`, затем `make setup` повторно.

После `make build` в `data/warehouse.duckdb` лежат все 11 моделей; для интерактивного просмотра удобно [`./duckdb-explore.sh`](duckdb-explore.sh): подключённая консоль к warehouse'у с парой готовых SELECT'ов.

### Известные ограничения локалки

Только на DuckDB; на BigQuery в проде не воспроизводятся.

- **Cold rebuild `stg_events` на 8 GB-машинах OOM'ит.** Источник: 5.7 M строк × жирный struct (`event_params`, `user_properties`, `device`, `geo`, ...). DuckDB-сессию SIGKILL'ит OS после ~7 GB spill'а. На ≥ 16 GB машинах model SQL отрабатывает as-is, запускайте обычным `make build`. На ≤ 8 GB — `make build-small`: вызывает `python scripts/build_stg_batched.py` (114 чанков × ~50K по `event_date`, дедуп локален к дню), затем `dbt build --exclude stg_events`. Шаблон SQL в скрипте зеркалирует `models/staging/stg_events.sql` и должен синхронизироваться при правке модели — на BigQuery скрипт не нужен.
- **`profiles.yml` зажат под маленькие машины:** `threads=1`, `memory_limit=1500MB`, `preserve_insertion_order=false`. На BQ-проде эти настройки не применяются (это локальный duckdb-профиль).
- **Dedup переписан с `qualify row_number() over (...)` на hash-aggregate** (`list(_src_rowid order by ...)[2:]` + anti-join). Логически идентично, footprint меньше; bottleneck OOM'а это не убирает (он в типизированной проекции / write-фазе). Подробности в коммитах `cdea1cb` и `9b091db`.

---

## 2. Что я сделал и почему: карта решений

### 2.1. Артефакты по частям ТЗ

| Часть | Что | Где лежит |
|---|---|---|
| 1. Разведка данных | Полный EDA + free-form ответы; каталог 13 аномалий, identifier model, монетизация | [`docs/data_exploration.md`](docs/data_exploration.md); free-form ответ оформлен как doc-блок к источнику `raw.events` ([`models/staging/_raw_events__eda.md`](models/staging/_raw_events__eda.md), рендерится в `dbt docs` через `make docs`) |
| 2. Продуктовая постановка | 16 фиксированных решений (identity, cohort anchor, окно D30, definition of active, slices) с обоснованиями | §3 этого файла |
| 3. dbt-проект | 11 моделей в 5 слоях (staging -> int -> utils -> marts/core -> marts/reports), ~70 generic + 8 singular + 11 unit ≈ 90 тестов; tier-фрейм и принципы | `models/`, `tests/`, [`docs/decisions/architecture.md`](docs/decisions/architecture.md), [`docs/decisions/testing-strategy.md`](docs/decisions/testing-strategy.md) |
| 4. Витрины + дашборд-скетч | 4 mart'а под BI (overall + by_platform на retention/revenue), single-page wireframe, 6 PNG-мокапов чартов на real/illustrative numbers | `models/marts/reports/`, [`docs/dashboard_sketch.md`](docs/dashboard_sketch.md), `docs/img/dashboard/`, [`scripts/render_dashboard_mocks.py`](scripts/render_dashboard_mocks.py) |
| 5. Кастомный скилл | `dbt-docs`: превращает заметки/EDA-маркдаун в чистый `_models.yml` с пометкой gaps через `[CHECK]` + tag `check` (`dbt ls --select tag:check`) | [`skills/dbt-docs/`](skills/dbt-docs/) |
| 6. README | Этот файл | `README.md` |

### 2.2. Архитектура (TL;DR)

```
raw.events                                                   [source]
   │
   ▼
stg_events  ─────────────────────────────────────────────── [staging, view]
   │   типизация (UTC), dedup, распаковка event_params, промоут структов
   │
   ├──► int_user_install ─┐                                [int, view]
   ├──► int_user_daily_activity ─┐
   └──► int_user_daily_revenue ──┤
                                  │
                                  ▼
                          dim_users + fct_user_daily   ★    [marts/core, table]
                          (user × activity_date, sparse)
                                  │
                                  │ + day_numbers spine (D0..D30)
                                  ▼
              mart_retention_overall / mart_retention_by_platform
              mart_revenue_overall   / mart_revenue_by_platform     [marts/reports, table]
                                  │
                                  ▼
                          BI (headless: SELECT * + WHERE)
```

**Ключевое решение:** центральный факт `fct_user_daily` на грейне `(user_pseudo_id × activity_date)`, **sparse** (только дни с фактом). Любой будущий отчёт (когорты, funnels, weekly retention, A/B-разрезы) собирается одним SELECT поверх звезды `dim_users + fct_user_daily` без переделки `core`.

Дашборд читает только `marts/reports/*`: никакой бизнес-логики на стороне BI, mart'ы под чарты 1-в-1 (см. таблицу per-block в [`docs/dashboard_sketch.md`](docs/dashboard_sketch.md) §3).

Полное обоснование (9 ключевых архитектурных решений с альтернативами, которые отвергли) в [`docs/decisions/architecture.md`](docs/decisions/architecture.md) §4 «Ключевые архитектурные решения».

### 2.3. Тесты (TL;DR)

- **~70 generic + 8 singular + 11 unit ≈ 90 тестов.** Density перевёрнута относительно «наивного» разложения: **core ~12 тестов на модель**, reports ~7 на mart, потому что core это source of truth для downstream витрин, и его инварианты должны быть толще.
- **Tier-фрейм** (1: PK/FK всегда, 2: discovery-driven `accepted_values`, 3: один критический `expression_is_true` на модель, 4: avoid). Каждый инвариант стоит **только на одном слое**, не дублируется по staging/int/core, как было в первой итерации.
- **5 dimensions DQS** (Completeness / Consistency / Validity / Uniqueness / Timeliness): каждый критический грейн покрыт хотя бы одним тестом per dimension.
- **Singular'ы** закрывают то, что generic не выражает: end-to-end reconciliation (`SUM(gross_revenue)` в марте = `SUM(event_value_in_usd)` в стейдже), монотонность кумулятивов, D0=1.0, fct vs dim cohort_date consistency.
- **Unit-тесты:** 11 штук на сложной SQL-логике: sparse-семантика `fct_user_daily` (3), p99-граница в `dim_users` (1), `bool_or`-семантика `is_reinstall` (1), `cum_arppu` NULL-handling + cumulative correctness в `mart_revenue_overall` (3), trailing baseline edge-cases в retention mart'ах (3: first-cohort NULL, partial-window accumulation, per-platform independence).

Принципы отбора и распределение по слоям — в [`docs/decisions/testing-strategy.md`](docs/decisions/testing-strategy.md).

---

## 3. Допущения и уточнения

Самое важное:

1. **Identity = `user_pseudo_id`.** `user_id` 100% NULL, `ga_session_id` всегда отсутствует: это единственный 100%-покрытый стабильный ключ.
2. **Cohort anchor = `min(event_date_utc) per user_pseudo_id`.** `user_first_touch_timestamp` врёт у 97% пользователей; `first_open` event есть только у 28%. Только «первое наблюдённое событие» даёт 100% покрытие.
3. **Date axis = UTC** (`event_date_utc = event_timestamp::date`). Локальный `event_date` и UTC расходятся на 34% строк, нужен один якорь.
4. **Activity = ≥ 1 любое событие в день.** Самое инклюзивное; `session_start` есть только у 81% пользователей.
5. **Retention type = classic D-N** (активен ровно в день N), не rolling. F2P-канон, BI рисует cohort-triangle без window-функций.
6. **Window = D0..D30.** Окно сэмпла 114 дней, даже последняя дневная когорта (2018-09-03) имеет полный D30 в данных.
7. **Revenue = `event_value_in_usd` на `in_app_purchase`.** Не `user_ltv.revenue`: он включает покупки до окна, которые нельзя attribute к нашему `cohort_date`. Currency: всё в USD без конверсии (Firebase уже сконвертил).
8. **Re-installs не вычитаем**, только флажок `is_reinstall` в `dim_users`, продакт сам решает, фильтровать ли.
9. **Slices = `platform`, `country` (Top-5 + Other), `traffic_medium`.** Реализованы только `*_by_platform` mart'ы; `country`/`traffic` тривиально расширяются по тому же шаблону (5 минут копипаст).
10. **Left-censored когорта 2018-06-12** остаётся в марте, но помечается флажком; из агрегатных KPI типа «средний D7 retention» исключается (449 пользователей, по построению все «новые»).
11. **Bot/quality exclusion** - Не фильтруем; флажок `is_outlier_events` в `dim_users` для `events > p99` (≈ 5 541) — дашбордер сам решает. Явных ботов нет; max 102 503 events на пользователя подозрительно, но не повод тихо вычистить.

### 3.1. Что осознанно НЕ строим

- **`fct_user_event`** (событийный факт). Дашборд не требует event-level drill-down; `stg_events` остаётся единственным местом грейна «событие».
- **Session-level mart.** `ga_session_id` 100% пуст, `session_start` есть только у 81% юзеров. Реконструкция сессий это отдельная задача с серьёзной погрешностью.
- **Funnel mart по геймплею** (`level_start -> level_complete -> ...`): продакт не просил.
- **A/B-разрезы (`firebase_exp_*`)**: не озвучены в брифе. Добавляются как новые колонки в `dim_users` + новый report без изменений в `core`.
- **Прогноз LTV / predicted retention**: это ML-задача, не аналитика.
- **`mart_*_by_country` / `mart_*_by_traffic`**: паттерн идентичен `*_by_platform`; задокументирован как extension point. Traffic отдельно: paid < 1% трафика, 24 платящих на весь сэмпл, slice по traffic medium даёт пустые ячейки, descope-нут осознанно.

Полная аннотация в [`docs/decisions/architecture.md`](docs/decisions/architecture.md) §5 «Что мы намеренно НЕ строим».

---

## 4. Trade-offs

Что выбрал и что бы сделал иначе при большем времени.

| # | Что выбрал сейчас | При большем времени / на проде | Почему компромисс |
|---|---|---|---|
| 1 | `staging` = view, без partition / incremental | На BQ: `materialized=incremental`, `partition_by=event_date_utc`, `unique_key=(user_pseudo_id, event_timestamp, event_name)`, `incremental_strategy='merge'` | DuckDB+5.7M строк = миллисекунды; SQL остаётся тот же, меняется только конфиг. Подготовился к миграции, не платя сложность сейчас. |
| 2 | `fct_user_daily` **sparse** (только дни с фактом), densify в `reports/` через JOIN с `day_numbers` | То же на BQ, плюс `partition_by=activity_date`, `cluster_by=(user_pseudo_id, cohort_date)` | Dense fct содержит ~60% строк с `is_active=0`, байты, которые читаются впустую при каждом scan'е. Densify через date-spine на BQ on-demand почти бесплатна (spine крошечный); семантика чище: «факт» = «произошло». |
| 3 | Реализованы только `*_by_platform` mart'ы (4 из 8 возможных) | + `*_by_country`, `*_by_traffic` (2× копипаст шаблона, замена slice-колонки) | Демонстрируется pattern; добавление = 5 минут на mart. Раньше времени плодить узкие mart'ы это лишний шум. |
| 4 | Дашборд = single-page long-scroll | На проде с 3+ срезами и 10+ чартами: табы Retention / Monetization | Для тестового на 114 днях и 4 mart'ах табы это overkill. Решение пересматривается при росте surface'а. |
| 5 | Trailing 4w baseline считается **в марте** через макрос `retention_trailing_avg` (✅ реализовано) | Альтернатива была: оставить window-AVG на BI-стороне | На стороне BI это нарушало бы headless-принцип на одном чарте. Макрос `retention_trailing_avg(partition_by, days=28)` решает это в SQL за 5 строк, переиспользуется в overall и by_platform mart'ах. |
| 6 | `profiles.yml` зажат под 8 GB машины (`threads=1`, `memory_limit=1500MB`) | На проде стандартный thread-pool BQ (irrelevant) | Без капов cold rebuild SIGKILL'ится на 8 GB. Цена: builds на больших машинах работают медленнее, чем могли бы. Acceptable trade-off для воспроизводимости (см. коммит `9b091db`). |
| 7 | Dedup в `stg_events`: hash-aggregate (`list_agg(_src_rowid)[2:]` + anti-join), не `qualify row_number()` | На BQ обратно `qualify` (естественно ложится) | DuckDB `qualify` требует глобального sort'а на 5.7M; hash-aggregate per-group sort внутри `having count(*) > 1` (99% групп выкидываются). Memory footprint меньше, миграция на BQ через `qualify` чистая. Сам OOM это не лечит, bottleneck в write-фазе. |
| 8 | Cold-rebuild OOM workaround = **батчировать вручную** через 114 INSERT'ов по `event_date` | Вшить в модель через pre/post-hook или Python-runner поверх dbt | ⚠ Workaround зафиксирован в README, но не вшит. Логика батч-инжеста не инкапсулируется чисто в dbt-модель (нужен Python wrapper или pre-hook с цикл-Jinja). На ≥16 GB не нужно, приоритет был ниже остальных задач. |
| 9 | Density тестов: **core толще, reports тоньше** (~12 vs ~7 на модель) | То же, намеренная конфигурация, не trade-off | Изначально было наоборот (30 тестов на 4 mart'а vs 13 на core). Reverted после tier-аудита: source of truth должен быть толще, а на reports `not_null` поверх `coalesce(..., 0)` low-signal. |
| 10 | Скилл = `dbt-docs` (форматтер YAML с gap-tagging) | Скилл для нового источника / scaffold staging-моделей из схемы | Из 5 идей в ТЗ выбрал ту, где у меня была наиболее чёткая модель «какой output клиенту нужен»: clean `_models.yml` с `[CHECK]`-маркерами на gaps. ⚠ Скилл адаптирован из вендорного `dbt`-плагина, не написан с нуля; в `SKILL.md` отмечен origin. |
| 11 | Все mart'ы = `table` (full-refresh каждую сборку) | На BQ incremental по партиции для свежих когорт + full-refresh окном для backfill | На DuckDB 5.7M исходных строк = секунды на rebuild всех mart'ов. На проде 5.7M/день нужна incremental-стратегия с `partition_by=cohort_date` и `incremental_strategy='insert_overwrite'`. |
| 12 | Footnote'ы дашборда хардкодятся в BI-tooltip'ах | Метаданные в `_models.yml` -> автоматически в `dbt docs` -> импортируется в BI-config | Tooltip'ы привязаны к BI-инструменту; абстракция «meta -> BI» зависит от выбора BI (см. §6 «Вопросы»). |

---

## 5. Как бы я оркестрировал это в Airflow

⚠ Описание гипотетическое, Airflow в проекте не материализован.

### 5.1. DAG-разбиение

Один проект -> **3 связанных DAG'а**, разделённых по SLA и ответственности:

1. **`firebase_export_to_warehouse`** (внешний контракт; владелец: data-platform, не AE)
   - Источник: Firebase BigQuery export (typical SLA: события дня D доступны после 06:00 UTC дня D+1).
   - Шаги: `BQ-export -> object-store landing -> ingest в warehouse (raw.events)`.
   - На выходе пишет sentinel в metadata-table: «партиция D готова».

2. **`dbt_models_daily`** (наш): собственно трансформации.
   - Trigger: ExternalTaskSensor на sentinel из (1).
   - Один DAG, три task-group'ы по слойной архитектуре:
     - `staging_intermediate`: `dbt build --select +stg_events int_user_install int_user_daily_activity int_user_daily_revenue` (incremental на свежий день).
     - `marts_core`: `dbt build --select dim_users fct_user_daily` (incremental по `cohort_date` и `activity_date` партициям; full-refresh weekly для пересчёта `is_outlier_events` baseline).
     - `marts_reports`: `dbt build --select marts.reports` (full-refresh окном «последние 30 cohort_date» + incremental поверх). 4 task'а параллельно (4 независимых mart'а).
   - В конце каждой task-группы: `dbt test --select <group>` (тесты моделей группы).

3. **`dbt_freshness_and_observability`** (отдельный)
   - Cron: каждые 4 часа.
   - Шаги: `dbt source freshness` -> парсинг `sources.json` -> метрики в Prometheus/Grafana -> alert через alertmanager при `warn/error` на freshness.

### 5.2. Расписание

- `firebase_export_to_warehouse`: суточно, ~05:30 UTC (под Firebase SLA).
- `dbt_models_daily`: триггерится сенсором, обычно стартует ~06:30 UTC, ETA ~15 минут (на полном датасете BQ больше зависит от incremental partition size'а).
- `dbt_freshness_and_observability`: каждые 4 часа.

### 5.3. Зависимости и selectors

- Внутри `dbt_models_daily`: явные task-зависимости через TaskGroup'ы (`staging_intermediate >> marts_core >> marts_reports`), внутри groups параллельность по dbt-селекторам.
- На уровне dbt: `+stg_events` для upstream, `marts.core+` для downstream-impact, `state:modified+` в CI для PR-prune'ов.
- Backfill: ручной trigger DAG'а с параметром `cohort_date_from / cohort_date_to`; передаётся в dbt vars `--vars '{backfill_from: ..., backfill_to: ...}'`, инкрементальные модели читают эти vars в `where` условиях фильтра партиций.

### 5.4. Обработка сбоев

- **Source freshness gate** (отдельный pre-task в DAG'е): если `dbt source freshness` возвращает `error` (партиция D отсутствует в raw.events), DAG fail'ится с ясной диагностикой, без попыток собирать пустые mart'ы. На статичном публичном сэмпле этот gate отключён (zero-day SLA не имеет смысла на 2018-09 данных).
- **Tier 1 тесты (PK/FK)** = `severity: error` -> fail таска -> fail всей task-group -> downstream task'и помечаются `upstream_failed`, PagerDuty wakes oncall.
- **Tier 3 (`expression_is_true`)** можно конфигурить `severity: warn` для не-критичных инвариантов -> лог в Slack-канал `#dbt-warns`, не будит ночью.
- **Drift-watchers** (`severity: warn`, см. `docs/decisions/testing-strategy.md` §5): только лог, без alert'а; цель наблюдать тренд через Grafana.
- **Idempotency**: incremental modes используют `unique_key`, retry таска на том же partition'е безопасен.
- **Atomic mart writes**: на BQ через `insert_overwrite` партиций, на DuckDB через `create or replace table`, failure посередине не оставляет half-written mart'ов.
- **Backfill flow**: `--full-refresh` запускается из отдельного DAG'а `dbt_backfill_manual` с обязательным confirm-параметром, чтобы случайный full-refresh на проде не пересчитывал годы данных.

### 5.5. Наблюдаемость

- `dbt run` пишет `target/run_results.json` и `manifest.json` -> загружается task'ом-postprocessing в metadata-таблицу (`dbt_metadata.runs` / `.tests` / `.timing`).
- Поверх metadata-таблицы Grafana-дашборд с ключевыми метриками: per-model duration trend, test pass rate, freshness lag.
- Важные failures (Tier 1) -> Slack `#data-alerts` + PagerDuty; warns -> `#dbt-warns`; daily summary -> Slack `#data-digest` в 09:00.

---

## 6. Вопросы, которые я задал бы в реальном проекте

Решения, зафиксированные в §3, выбраны под публичный 2018-сэмпл, на проде их стоит верифицировать.

### Продуктовые

1. **Что значит «новый игрок»**: впервые увиденный за всё время сэмпла, или впервые после конкретной маркетинговой кампании? Сейчас первое.
2. **D7 или D30 для «первых дней»?** Достаточно ли D7, или нужны длинные хвосты до D30? Сейчас D30.
3. **Activity = что именно**: любое событие, `session_start`, или строго геймплей-событие (`level_start_*`)? Сейчас любое событие, но это вопрос ценности «зашёл и открыл меню = активный».
4. **Re-installs**: считать как новую когорту, склеивать с первой установкой, или вычеркивать? Сейчас новая когорта + флажок `is_reinstall` на product self-serve.
5. **Окно ретеншна для платящих**: ARPPU только по платящим в первые N дней, или по всем платящим в когорте за всё время? Сейчас по всем в окне D30.
6. **Critical KPIs**: что именно показывать на header'е дашборда: D7-retention в среднем по периоду, или последняя полная когорта? (Разные формулы, разная стабильность; см. [`docs/dashboard_sketch.md`](docs/dashboard_sketch.md) §3.)
7. **Что делать с left-censored когортой 2018-06-12?** Сейчас оставляем в марте с флажком, исключаем из агрегатных KPI. На реальной проде такого артефакта не будет (full history).

### Инфраструктурные

8. **Latency / SLA**: суточное обновление окей, или нужен near-real-time? Сейчас ориентир на ежесуточный refresh после Firebase-export SLA. NRT потребует переезда на Streaming inserts + materialized views в BQ.
9. **Ownership витрин**: кто owner за `mart_*` таблицы? AE-команда, или передаём в analytics-team как stable interface? От этого зависит SLA на breaking changes.
10. **Backfill policy**: как часто перестраиваем исторические партиции (sparse `fct_user_daily` это упрощает, но не отменяет)? И с какого момента в прошлом делаем полную пересборку при изменении бизнес-логики (например, нового определения active)?
11. **Cost guardrails на BQ**: при on-demand pricing какой quota cap на день / месяц? Sparse + partitioned mart'ы держат типичный dashboard-query в пределах одной партиции (~5-10 MB), но full-refresh `mart_revenue_overall` поверх 5 лет данных другая история.

---

## 7. Структура репозитория

```
.
├── README.md                       # этот файл
├── README_base.md                  # ⚠ исходный setup-only README,
│                                   #   удалю после ревью этого файла
├── TEST_ASSIGNMENT.md              # оригинальное ТЗ
├── Makefile                        # setup / build / docs / clean
├── requirements.txt                # зафиксированные зависимости
├── packages.yml                    # dbt_utils
├── profiles.yml                    # dbt-профиль для DuckDB (capped)
├── dbt_project.yml                 # конфигурация dbt-проекта
├── duckdb-explore.sh               # interactive console + cheat-sheet
│
├── scripts/
│   ├── prepare_data.py             # Google Drive -> data/firebase_events.parquet
│   └── render_dashboard_mocks.py   # matplotlib-рендер 6 PNG-мокапов
│
├── data/                           # БД DuckDB и parquet (gitignored)
│
├── models/
│   ├── staging/
│   │   ├── _sources.yml            # source-контракт raw.events (+ ссылка на doc-блок)
│   │   ├── _raw_events__eda.md     # Part 1: free-form EDA как doc-блок к raw.events
│   │   ├── _models.yml
│   │   └── stg_events.sql          [view]
│   ├── intermediate/
│   │   ├── _models.yml + _unit_tests.yml
│   │   ├── int_user_install.sql            [view] user-grain
│   │   ├── int_user_daily_activity.sql     [view] user-day grain
│   │   └── int_user_daily_revenue.sql      [view] user-day grain
│   ├── _utils/
│   │   └── day_numbers.sql                 [view] D0..D30 spine
│   └── marts/
│       ├── core/
│       │   ├── _models.yml + _unit_tests.yml
│       │   ├── dim_users.sql               [table]
│       │   └── fct_user_daily.sql          [table]   ★ central fact
│       └── reports/
│           ├── _models.yml + _unit_tests.yml
│           ├── mart_retention_overall.sql       [table]
│           ├── mart_retention_by_platform.sql   [table]
│           ├── mart_revenue_overall.sql         [table]
│           └── mart_revenue_by_platform.sql     [table]
│
├── macros/
│   ├── cum_sum.sql                 # cumulative window helper
│   ├── retention_trailing_avg.sql  # trailing 4w baseline (Block 3)
│   └── revenue_metrics_columns.sql # shared SELECT-list для revenue mart'ов
│
├── tests/                          # 8 singular business-checks
│   ├── assert_cohort_size_reconciliation.sql
│   ├── assert_cum_revenue_monotonic.sql
│   ├── assert_cum_revenue_monotonic_by_platform.sql
│   ├── assert_d0_full_retention.sql
│   ├── assert_d0_full_retention_by_platform.sql
│   ├── assert_fct_dim_cohort_date_consistency.sql
│   ├── assert_paying_users_reconciliation.sql
│   └── assert_revenue_reconciliation.sql
│
├── docs/
│   ├── data_exploration.md         # Part 1: full EDA
│   ├── dashboard_sketch.md         # Part 4: wireframe + per-block specs
│   ├── img/dashboard/              # 6 PNG мокапов (matplotlib)
│   └── decisions/
│       ├── architecture.md         # Part 3: принципы, ключевые решения, BQ-mig
│       └── testing-strategy.md     # Part 3: tier-фрейм, DQS, severity
│
└── skills/
    └── dbt-docs/
        ├── SKILL.md
        └── references/examples.md
```

---

## 8. Куда смотреть, чтобы войти

- **«Я ревьюер, у меня 10 минут»**: этот README + быстрый просмотр [`docs/decisions/architecture.md`](docs/decisions/architecture.md) §TL;DR + §1 «Принципы дизайна».
- **«Хочу понять, что в данных»**: [`docs/data_exploration.md`](docs/data_exploration.md).
- **«Хочу понять, что считаем и почему именно так»**: §3 этого файла.
- **«Хочу понять архитектуру и материализации»**: [`docs/decisions/architecture.md`](docs/decisions/architecture.md).
- **«Хочу понять, как тестируется»**: [`docs/decisions/testing-strategy.md`](docs/decisions/testing-strategy.md).
- **«Хочу увидеть дашборд глазами продакта»**: [`docs/dashboard_sketch.md`](docs/dashboard_sketch.md).
- **«Хочу пощупать данные руками»**: `make build`, затем `./duckdb-explore.sh`.
