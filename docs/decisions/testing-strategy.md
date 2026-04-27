# Стратегия тестирования

Один вход для AE: какими принципами руководствуется тестовый слой dbt-проекта. Перечисления конкретных тестов и их количества здесь нет — их роль играет код в `_models.yml` и `tests/`. Этот файл фиксирует **решения**, по которым тесты добавляются, удаляются и распределяются по слоям.

Методологические опоры:
- [`docs/decisions/architecture.md`](architecture.md) — слои и материализации; стратегия опирается на эту структуру.
- `models/staging/_raw_events__eda.md` — статические факты о публичном сэмпле, которые **не превращаются в тесты**, а живут как документация источника.
- - `.claude/skills/using-dbt-for-analytics-engineering/references/writing-data-tests.md` — Tier-фреймворк, layer-specific guidance.
- `.claude/skills/adding-dbt-unit-test/SKILL.md` — когда писать unit-тесты, формат `dict`.
- `.claude/skills/data-quality-auditor/SKILL.md` — DQS-фрейминг (5 dimensions).
- `git show feature/part-1-data-exploration:docs/eda_tests.md` — каталог инвариантов, выписанный в EDA.

---

## TL;DR

- **Каждый инвариант — на одном слое**, не дублируется по staging / intermediate / core / reports.
- **Статика — в документацию, инварианты — в тесты.** Если факт «50k/день» зависит от датасета, а не от трансформации, он живёт в doc-блоке источника, не в `_sources.yml` тесте.
- **Tier-фрейм** (1: PK/FK всегда, 2: `accepted_values` где EDA подтвердил узкий домен, 3: один критический `expression_is_true` на модель, 4: avoid) — фильтр на «нужно ли это тестировать вообще».
- **5 DQS-измерений** (Completeness / Consistency / Validity / Uniqueness / Timeliness) — каждый критический грейн покрыт хотя бы одним тестом per dimension.
- **Density: core толще reports.** На source of truth — полный набор инвариантов; на reports — sanity на бизнес-логику и кумулятивы, не `not_null` поверх `coalesce(..., 0)`.
- **Singular = end-to-end сверки и кросс-слойные консистенции**, generic — структура и значения колонок; unit — сложная SQL-логика на детерминированных фикстурах.

---

## 1. Принципы отбора

### 1.1. Tier-фрейм

| Tier | Когда применяем | Типичные тесты |
|---|---|---|
| 1. Always | PK / FK | `unique`, `not_null`, `relationships` |
| 2. Discovery-driven | Колонка с подтверждённым EDA узким доменом или 0 % null на критическом поле | `accepted_values`, `not_null` на не-PK |
| 3. Selective | Один критический инвариант на модель; ограниченные диапазоны | `expression_is_true`, `accepted_range` |
| 4. Avoid | Низкая ценность / высокая стоимость | `not_null` на каждой колонке, стопка `expression_is_true` без фокуса, `unique` на не-PK |

Правило: тест из Tier 4 не пишем. Tier 2 обязан опираться на конкретное наблюдение в EDA, иначе уезжает в Tier 4. Tier 3 — не больше одного per модель; больше — повод вынести в singular или unit.

### 1.2. DQS-измерения

Каждый тест помечается одним из пяти измерений (в `meta:` или комментарии):

| Измерение | Что меряет | Где обычно живёт |
|---|---|---|
| Completeness | Null / missing на критических колонках | `not_null` |
| Consistency | Соответствие типов, форматов; reconciliation между слоями | `unique_combination_of_columns`, end-to-end singular'ы |
| Validity | Значения в ожидаемом домене | `accepted_values`, `accepted_range`, `expression_is_true` |
| Uniqueness | Нет дублей PK | `unique`, `unique_combination_of_columns` |
| Timeliness | Свежесть таймстемпов | `freshness` на source |

Цель — на каждом критическом грейне (raw event, user, user-day, cohort × day, cohort × day × slice) минимум один тест per measurement. Перекос «20 unique-тестов и ноль validity» — сигнал перераспределить density.

### 1.3. Тестируем или документируем?

**Тестируем** — то, что трансформация **должна** обеспечивать. Это про инвариант на код, а не про факт в данных.

**Документируем** — статические факты о датасете, которые держатся «по случаю» и могут легитимно измениться:

- Диапазон дат публичного сэмпла (2018-06-12 … 2018-10-03) — факт про сэмпл, не про код.
- 50 000 событий в день — артефакт публичного сэмпла, на проде сразу станет ложью.
- `country_top5` — список считается динамически по данным, у `'Other'` fallback нет фиксированного контракта.

Правило: если изменение факта = «данные изменились легитимно», а не «трансформация сломалась» — это в документацию, не в тест.

### 1.4. Один инвариант — один слой

Один и тот же инвариант ставится **только в одном месте**. Для пасс-тру колонок (`platform` идёт через `stg_events` → `int_user_install` → `dim_users` без изменений) тест ставится **наверху** (на source), ниже не дублируется. Для производных колонок — на слое, где колонка **впервые появляется**.

Эффект: при breaking change в источнике падает один тест на правильном слое; не каскад из четырёх одинаковых.

---

## 2. Распределение по слоям

| Слой | Что ловит | Что **не** делает |
|---|---|---|
| `_sources.yml` | Структурный контракт сырья: PK-колонки `not_null`, узкие домены через `accepted_values`. На проде — `freshness`. | Не тестирует статику сэмпла (50k/день и т. п.); не дублирует инварианты, которые ниже выражены через staging-`expression_is_true`. |
| `staging` | Гигиена: dedup, типы, sanity-инварианты на промоут struct → top-level (`event_value_in_usd > 0` ⇒ `event_name = 'in_app_purchase'`). | Не дублирует source-`accepted_values` для пасс-тру колонок. |
| `intermediate` | Минимум — `not_null` на PK для fast-fail. | Не покрывает уникальность и `accepted_values`: эти инварианты строже стоят на `dim_users` / `fct_user_daily`. |
| `marts/core` | `relationships → dim_users`, бизнес-инварианты (`gross_revenue ≥ 0`, `paying_flag ⇔ gross_revenue > 0`, `events ≥ 1`). | Не повторяет source-контракт. |
| `marts/reports` | Sanity на агрегаты и производные поля (`retention_pct ∈ [0,1]`, `paying ≤ cohort`, `cum_arppu = cum_revenue / cum_paying_users`). | Не ставит `not_null` поверх `coalesce(..., 0)`-колонок и `count(*)`-выходов: SQL уже синтаксически гарантирует non-null. |
| `tests/` (singular) | Что generic не выразит: end-to-end сверки сырьё ↔ mart, монотонность по `partition by`, кросс-слойную консистенцию денормализованных полей. | Не дублирует то, что `expression_is_true` ловит на колонке. |
| Unit-тесты | Сложная SQL-логика на детерминированных фикстурах. См. §3. | Не подменяют data-тесты на структуре и не тестируют простые проекции. |

**Density:** на core тестов на модель в среднем больше, чем на reports. Source of truth должен быть толще; reports — тоньше, потому что бизнес-инварианты на агрегатах часто тривиальны (`gross_revenue ≥ 0` уже стоит на core).

---

## 3. Когда unit, а не data

Unit-тестам уходит **сложная SQL-логика, которую data-тест не зафиксирует точечно**:

- **Join + COALESCE + производное поле** в детерминированном случае: «юзер активен в D и купил в этот же D» → одна строка с `paying_flag = true`. Data-тест увидит «всё ок в среднем», unit — что **именно эта** строка собралась правильно.
- **Window-функции с NULL-edge case**: `cum_arppu` на когорте без платящих → `NULL`, а не `0/0`. В реальных данных воспроизводится в < 1 % когорт; unit ловит детерминированно.
- **Boolean-агрегации**: `is_reinstall = bool_or(previous_first_open_count > 0)` против `max(...)` — лёгкая регрессия при рефакторинге, NULL-семантика отличается.
- **Строгие неравенства в `case`**: outlier `> p99` (а не `≥`) — одна строка кода, data-тест границу не зафиксирует.
- **Densification на пустых ячейках**: когорта без платящих в D5 → строка существует с `gross_revenue = 0`, `paying_users = 0`.

**Unit не пишем** на простые проекции (staging-дедуп — корректность подтверждается `unique_combination_of_columns` на реальных 5.7 M), GROUP BY без сложной логики, встроенные функции (`generate_series`).

Формат фикстур — `dict` inline в YAML (минимум кода). CSV/SQL только если фикстура не помещается в YAML по размеру.

---

## 4. Singular vs generic

Singular пишем, когда инвариант **не выражается через колоночный generic**:

1. **End-to-end сверки** — закрытие петли «сырьё ↔ mart»: `sum(gross_revenue)` в марте = `sum(event_value_in_usd)` в `stg_events`; `count(distinct user_pseudo_id)` платящих в марте = в стейдже. Generic смотрит одну колонку одной модели — здесь нужно две.
2. **Монотонность по partition'у** — `cum_*` неубывает внутри `cohort_date` (× `slice` для by-platform). `expression_is_true` сравнивает значение со значением **в той же строке**, оконные сравнения через generic не выражаются.
3. **Кросс-слойная консистенция денормализованных полей** — `fct_user_daily.cohort_date == dim_users.cohort_date` для каждого `user_pseudo_id`. Generic-тест на колонке `fct_user_daily.cohort_date` смотрит только саму fct и расхождения с `dim_users` не ловит.
4. **D0 retention = 1.0** — по построению, но требует select из mart'а с фильтром.

Если инвариант выразим как `expression_is_true` на одной колонке — пишем generic. Дешевле и автодокументируется в `dbt docs`.

---

## 5. Severity и drift-watchers

- **`error`** — Tier 1 (PK/FK), бизнес-инварианты на core, end-to-end сверки. Падение блокирует merge.
- **`warn`** — drift-watchers: фиксируем baseline (доля 1-day-юзеров, доля `traffic_medium = '(none)'`, доля `device_os IS NULL`, доля реинсталлов), алертим на дрейф. Не fail/pass — наблюдательный слой.
- **Freshness на source** — на статичном публичном сэмпле **не декларируем** (он не «свежеет» по построению). На проде возвращается через `loaded_at_field` + `warn_after: {count: 1, period: day}`. Зафиксировано в README как известная особенность датасета.

Drift-watchers сейчас **отложены**: baseline фиксируется в EDA, тесты добавляются, когда появляется потребность мониторить сдвиг (Grafana / алерт в `#dbt-warns`). Принцип же — `severity: warn` либо отдельный `mart_data_quality_metrics` под дашборд.

---

## 6. Что осознанно НЕ тестируем

- **Статику сэмпла** (50k/день, диапазон дат, 114 различных дат сплошняком) — не инвариант кода, а свойство публичного 2018-датасета.
- **Динамические артефакты** (`install_country_top5`, p99-порог `events_total`) — зависят от данных и легитимно меняются. Корректность fallback в `'Other'` и строгое неравенство `> p99` — через unit на детерминированной фикстуре.
- **Пасс-тру `accepted_values`** на каждом слое — `platform` тестируем один раз на source.
- **Дублирующие structural-тесты на intermediate.** `dim_users` уже даёт `unique + not_null` на `user_pseudo_id`, `fct_user_daily` — `unique_combination_of_columns + relationships`. Intermediate те же инварианты ловить второй раз не должен.
- **`_utils/day_numbers`** ничем кроме `not_null` — `generate_series(0, 30)` встроенная функция.
- **Unit-тесты на staging-дедупе** — реальные 5.7 M строк являются «фикстурой»; `unique_combination_of_columns` на staging адекватно подтверждает корректность.
- **Тесты, привязанные к dashboard-метрикам.** Дашборд — потребитель витрин, не источник инвариантов; тесты живут на dbt-моделях.

---

## 7. Категории инвариантов из EDA

EDA дал каталог инвариантов; в стратегии они укладываются в семь категорий, которые уже описаны выше как принципы. Эта таблица — карта «откуда тест» → «куда лёг», без перечисления конкретных файлов:

| Категория | Где имплементируется | Тип |
|---|---|---|
| End-to-end сверки сырьё ↔ mart (revenue, paying users, cohort size) | `tests/` | singular |
| Структурные синглтоны (`platform`, `currency`, валидные пары `(platform, app_id)`) | `_sources.yml` (`accepted_values`), `staging` (`expression_is_true`) | generic |
| Когортные инварианты (`retained ≤ cohort`, `D0 = 1.0`, `activity_date ≥ cohort_date`) | `marts/core` (generic), `tests/` (для D0 и cross-layer) | generic + singular |
| Монотонность кумулятивов | `tests/` | singular |
| Sanity на сырьё (`user_pseudo_id` not null, `event_value_in_usd ≥ 0`) | `_sources.yml`, `staging` | generic |
| Drift-watchers (доля 1-day, `(direct)/(none)`, NaN-OS, реинсталлы) | отложено; будущий `mart_data_quality_metrics` или `severity: warn` тесты | — |
| Бизнес-логика f2p (`level_complete` после `level_start`) | вне scope (продакт не подтвердил) | — |

---

## 8. Verification

Стратегия не предписывает «сколько тестов» — но проверяется тем же `dbt build`:

1. Зелёный `dbt build` — все Tier 1 тесты проходят на полном сэмпле.
2. На каждом критическом грейне в `_models.yml` — минимум один тест per DQS-измерение (где применимо).
3. Каждый тест в YAML / singular-файле сопровождён DQS-измерением и однострочной rationale в `meta:` или комментарии.
4. Один инвариант — один тест: `grep -r "accepted_values" models/` показывает каждый домен ровно один раз.

---

## 9. Спорные точки — резолюция

| # | Что | Решение |
|---|---|---|
| 1 | `freshness` на статичном DuckDB-сэмпле | Не декларируем; в README — как особенность датасета. На проде вернуть с `loaded_at_field`. |
| 2 | `accepted_values` на `country` / `event_name` / `device_category` | Не пишем (200+ значений / 37 / стабильные 2 — слишком хрупко или преждевременно). |
| 3 | `accepted_values` на `install_country_top5` | Не пишем — список динамический; fallback в `'Other'` проверяем unit-тестом. |
| 4 | `expression_is_true: cohort_date between …` | Не пишем — статический факт о датасете, документируем. |
| 5 | Drift-watchers | Отложены — фиксируем baseline в EDA, тесты добавляем по потребности. |
| 6 | Source-singular'ы (50k/день, пары `(platform, app_id)`, revenue-инвариант) | Не пишем — заменены `accepted_values` / `expression_is_true` на соседнем слое либо документацией. |
| 7 | Intermediate-тесты | Триммим до `not_null` на PK; уникальность покрыта downstream. |
