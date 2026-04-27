# Архитектура dbt-проекта

Один вход для AE: какими решениями обусловлена структура слоёв, грейн фактов и материализации. Колонки моделей, типы и описания живут в `_models.yml` и рендерятся в `dbt docs` — этот файл их не повторяет, а фиксирует **почему** архитектура именно такая.

Связанные документы:
- [`testing-strategy.md`](testing-strategy.md) — какими принципами тестируется архитектура.
- [`docs/data_exploration.md`](../data_exploration.md) — числа и аномалии источника, на которых стоят решения.
- `models/staging/_raw_events__eda.md` — doc-блок источника с EDA, рендерится в `dbt docs`.

---

## TL;DR

- 5 слоёв: `staging` → `intermediate` → `_utils` + `marts/core` → `marts/reports`.
- Центральный факт `fct_user_daily` на грейне **user × activity_date**, sparse (только дни с фактом).
- Дашборд читает только `marts/reports/*` — headless BI, никакой логики на стороне инструмента.
- BQ-ready: миграция меняет materialization-конфиги, не SQL.

---

## 1. Принципы дизайна

1. **Headless BI.** Любая бизнес-логика приземляется до `marts/reports/`. Дашборд делает `SELECT * FROM mart_* WHERE filter` — без window-функций, COUNT DISTINCT, JOIN'ов на BI-стороне.
2. **Атомарный факт на user-day grain.** В `core` лежит звезда `dim_users + fct_user_daily`. Любой будущий отчёт (когорты, funnels, weekly retention, A/B-разрезы) собирается одним SELECT поверх звезды без переделки нижних слоёв.
3. **Sparse факт.** В `fct_user_daily` лежат только дни с фактом — отсутствие строки = «ничего не произошло». И семантически правильнее, и дешевле в BigQuery (см. §3).
4. **Future-proofing для BQ.** Архитектура одинаково корректна для DuckDB (текущий рантайм) и BigQuery (целевой). Различия инкапсулированы в materialization-configs, не в SQL.
5. **Один источник истины для каждого фрагмента бизнес-логики.** Расчёт «что значит активный», «что считается revenue», «что такое cohort_date» — каждый ровно в одном месте.

---

## 2. Слои и их роль

| Слой | Роль | Материализация | Ключевое решение |
|---|---|---|---|
| `staging` | 1:1 с источником: типизация, dedup, распаковка `event_params`, промоут struct → top-level | view | Без фильтрации и агрегации; всё это — задача int/marts. На BQ → incremental по `event_date_utc`. |
| `intermediate` | Бизнес-преобразования между staging и marts: cohort_date, user-day агрегаты | view | Три отдельные view на разных грейнах (user, user-day activity, user-day revenue), не одна объединённая — у `revenue` свой фильтр на источнике. |
| `_utils` | Универсальные сущности | view | `day_numbers` как `generate_series` view, не seed-файл — ради 31 строки seed избыточен. |
| `marts/core` | Каноническая звезда `dim_users + fct_user_daily`. Не консумится BI напрямую. | table | star-schema: dim отдельно от fact, чтобы тесты `cohort_size` опирались на `dim_users` как independent SoT. |
| `marts/reports` | Дашборд-готовые таблицы. Каждая = один SELECT поверх core + day-spine. | table | Densify до решётки `cohort × day` живёт здесь, не в `core`. Изоляция: core = «что произошло», reports = «что показать». |

Полные определения колонок и грейн каждой модели — в `_models.yml` соответствующего слоя.

---

## 3. Центральный факт: грейн и sparseness

### Почему user-day grain, а не cohort × day × slice (cube)

1. Атомарный для F2P: «что юзер делал в день X» — это сам факт.
2. Любой будущий отчёт — это `GROUP BY` поверх звезды без изменений в `core`.
3. Per-user drilldown остаётся возможным, если продакт когда-то попросит.

Cube зафиксировал бы в `core` конкретный набор срезов и метрик; новый срез = переделка core. user-day-grain абстрагирует это.

### Почему sparse, а не dense

- На DuckDB разница незначима, проектируем под BigQuery.
- В BQ on-demand pricing scan-стоимость считается по байтам с диска. Dense fct содержит ~60 % строк с `is_active = 0` — байты, которые читаются впустую при каждом запросе.
- Densify через date-spine в reports: JOIN с `day_numbers` почти не считается в `bytes_scanned` (spine крошечный); сэкономленные scan'ы окупают сложность отчёта.
- Семантически чище: «факт» = «что произошло», а не «что мы хотим показать».

Колонки `is_active` нет — её роль играет наличие строки. Колонка была бы always TRUE.

### Densify в reports, а не в core

Альтернатива — densify в `core/fct_user_daily` или в `int_*`. Минус densify в core — при смене окна (например, до D60) переписывается факт-таблица; densify в reports — правится одна view (`day_numbers`). Цена децентрализации: 4 mart'а × ~3 строки densify-CTE; цена окупается на каждом следующем продакт-вопросе.

---

## 4. Ключевые архитектурные решения

| # | Решение | Альтернатива, которую отвергли | Почему |
|---|---|---|---|
| 1 | `core` на user-day grain (звезда `dim_users + fct_user_daily`) | Cohort × day × slice cube | Атомарный F2P грейн универсален; будущие отчёты добавляются без переделки core. |
| 2 | `fct_user_daily` sparse (только дни с фактом) | Dense (cross-product user × 0..30) | Sparse дешевле на BQ on-demand; densify в reports не платит за scan. Семантически: факт = «произошло». |
| 3 | Densify в `reports/`, не в `core` | Densify в `core/fct_user_daily` или в `int_*` | Изоляция: core = «что произошло», reports = «что показать». При смене max day_number правится одна view. |
| 4 | 4 derived mart'а (overall + by_platform на retention/revenue) | Все 8 (включая by_country, by_traffic) или один wide | Демонстрируем pattern; остальные тривиально расширяются. Читать дашборд из 8 узких mart'ов — самый headless вариант. |
| 5 | `staging` = view, без фильтрации | Сразу incremental table | DuckDB+5.7 M = миллисекунды. На BQ — менять только конфиг, не SQL. |
| 6 | Три отдельные `int_user_daily_*` (activity, revenue) | Одна объединённая | Разные источники в `stg_events` (фильтр по revenue vs всё подряд). Объединение давало бы лишний JOIN / UNION без выигрыша. |
| 7 | `dim_users` отдельно от `fct_user_daily` | Денормализация атрибутов в факт | Star-schema: slowly-changing атрибуты юзера в одном месте; тесты на `cohort_size` через `dim_users` как independent SoT. |
| 8 | Колонки `is_active` в факте нет | `is_active BOOLEAN` | Sparse fct: наличие строки = active. Колонка была бы always TRUE — избыточна. |
| 9 | `_utils/day_numbers` как view | Hardcoded `(0..30)` в каждом отчёте, или seed | View — единственное место для смены окна; seed-файл ради 31 строки избыточен. |

---

## 5. Что мы намеренно НЕ строим

- **`fct_user_event`** — отдельный факт на грейне события. Дашборд не требует event-level drill-down; `stg_events` остаётся единственным местом грейна «событие».
- **Session-level mart** — `ga_session_id` 100 % пуст в источнике; `session_start` event есть только у 81 % юзеров. Реконструкция сессий — отдельная задача с серьёзной погрешностью.
- **Funnel mart по геймплею** (`level_start → level_complete → ...`) — продакт не просил.
- **By-country / by-traffic reports** — тот же шаблон, что `*_by_platform`. Прописано как extension point; реализация — копипаст с заменой slice-колонки.
- **A/B-разрезы (`firebase_exp_*`)** — не озвучены в брифе. Добавляются как новые колонки в `dim_users` + новый report без изменений в `core`.
- **Прогноз LTV / predicted retention** — ML-задача, не аналитика.
- **Отдельные cube'ы под retention и revenue** — у них общий грейн фактов (`user × activity_date`); метрики живут в одной таблице.

---

## 6. Будущая миграция в BigQuery

Когда проект уезжает с DuckDB на боевой BQ, меняется только materialization-конфиг — SQL остаётся как есть.

| Слой / модель        | DuckDB сейчас | BigQuery target                                                                                                                                       |
| -------------------- | ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| `stg_events`         | view          | `materialized=incremental`, `partition_by=event_date_utc`, `unique_key=(user_pseudo_id, event_timestamp, event_name)`, `incremental_strategy='merge'` |
| `int_*`              | view          | view (или ephemeral, если DAG разрастётся)                                                                                                            |
| `dim_users`          | table         | table, `cluster_by=user_pseudo_id`                                                                                                                    |
| `fct_user_daily`     | table         | table, `partition_by=activity_date`, `cluster_by=(user_pseudo_id, cohort_date)`                                                                       |
| `mart_*_overall`     | table         | table, `partition_by=cohort_date`                                                                                                                     |
| `mart_*_by_platform` | table         | table, `partition_by=cohort_date`, `cluster_by=install_platform`                                                                                      |
| `day_numbers`        | view          | view                                                                                                                                                  |

**Стоимость на BQ-side**: при on-demand основной cost — scan'ы. Sparse fct + partitioned reports должны держать большинство dashboard-запросов в пределах одной партиции (~5–10 MB на typical query).

Несовместимости диалекта (`make_timestamp` → `TIMESTAMP_MICROS`, `list_filter(event_params, …)` → `UNNEST + WHERE`) выносятся в макросы с условием на `target.type` при первом dbt-builder'е под BQ; сейчас не материализованы (DuckDB-only).

---

## 7. Связь с тестами

Тестовый слой опирается на эту архитектуру; принципы — в [`testing-strategy.md`](testing-strategy.md). Стыки:

- **Source-контракт на `_sources.yml`, бизнес-инварианты на core, sanity на reports** — см. [`testing-strategy.md` §2](testing-strategy.md) «Распределение по слоям».
- **Star-schema (`dim_users + fct_user_daily`)** даёт independent SoT для `cohort_size` reconciliation: суммы платящих/cohort_size в марте сверяются с `dim_users`, а не с `fct_user_daily`.
- **Sparse факт + densify в reports** проверяется singular'ом `assert_d0_full_retention.sql` (densify не теряет когорту в D0) и тестами монотонности кумулятивов.
