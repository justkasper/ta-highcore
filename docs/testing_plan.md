# План тестирования

Документ фиксирует стратегию покрытия dbt-моделей тестами **перед** финальным документированием. Источник истины для последующей имплементации; спорные моменты подсвечены отдельно — их пользователь правит руками перед тем, как мы пойдём писать код.

Методологические опоры:
- `.claude/skills/using-dbt-for-analytics-engineering/references/writing-data-tests.md` — Tier-фреймворк, layer-specific guidance.
- `.claude/skills/adding-dbt-unit-test/SKILL.md` — когда писать unit-тесты, формат `dict`.
- `.claude/skills/data-quality-auditor/SKILL.md` — DQS-фрейминг (5 dimensions).
- `git show feature/part-1-data-exploration:docs/eda_tests.md` — каталог инвариантов, выписанный в EDA.
- `docs/architecture.md`, `docs/assumptions.md` — продуктовые и архитектурные решения.

Фокус по запросу: **stg + marts/core как «вход → выход»**, business-checks на marts, source-tests с freshness, unit-тесты на сложную SQL-логику.

---

## 1. TL;DR

- **Сейчас:** 75 generic + 6 singular = **81 тест**. 0 source-тестов, 0 unit-тестов. По модели: **в reports (30) больше, чем в core (13)** — обратное идеалу.
- **После имплементации:** ≈ **62 generic + 9 singular + 9 unit ≈ 80 тестов** — почти то же число, но **density перевёрнута**: core ~12 тестов на модель (×2 модели), reports ~7 на mart (×4 mart'а). Source наверху, intermediate тонкий, дубли ушли.
- **Слойная карта ответственности** (что ловит каждый слой):
  - `_sources.yml` — структурный контракт сырья (`not_null`, `accepted_values` на `platform`). Freshness не декларируем — публичный 2018-сэмпл статичен; зафиксировано в README.
  - `staging` — гигиена: dedup, типы, monetization sanity-инвариант, маппинг struct → top-level.
  - `intermediate` — минимум `not_null` на PK для fast-fail; уникальность не дублируется (покрыта downstream).
  - `marts/core` — relationships → `dim_users`, бизнес-инварианты + **unit-тесты** на сложную SQL-логику.
  - `marts/reports` — sanity на агрегаты + производные поля (`retention_pct ∈ [0,1]`, `paying ≤ cohort`, `cum_arppu = cum_revenue / cum_paying_users`).
  - `tests/` (singular) — end-to-end сверки сырьё↔mart, монотонности кумулятивов.
- **Принцип отбора:** Tier 1 (PK/FK) — всегда; Tier 2 (accepted_values, conditional not_null) — по результатам EDA, **только в одном месте на пайплайн**; Tier 3 (expression_is_true) — по одному критическому инварианту на модель; статические факты о датасете → документируем, **не тестируем**.

---

## 2. Принципы

### 2.1 Tier-фреймворк (из writing-data-tests.md)

| Tier | Когда применяем | Примеры |
|---|---|---|
| 1. Always | PK / FK | `unique`, `not_null`, `relationships` |
| 2. Discovery-driven | Колонка с подтверждённым набором значений или 0% null | `accepted_values`, `not_null` на не-PK |
| 3. Selective | Один критический инвариант на модель; ограниченные диапазоны | `expression_is_true`, `accepted_range` |
| 4. Avoid | Низкая ценность / высокая стоимость | `not_null` на каждой колонке, стопка `expression_is_true`, `unique` на не-PK |

### 2.2 Где живёт что (по слоям)

- **Source** — структурный контракт. Один тест per инвариант на одном слое; ниже не дублируем.
- **Staging** — data hygiene + проекция → top-level. Sanity-инвариант про монетизацию (`event_value_in_usd > 0` ⇒ `event_name = 'in_app_purchase'`).
- **Intermediate** — только `not_null` на PK (fast-fail). Уникальность и accepted_values покрыты соседними слоями.
- **Marts/core** — relationships → `dim_users`, бизнес-инварианты + unit-тесты на сложную логику.
- **Marts/reports** — sanity на агрегаты + производные поля.
- **Singular `tests/`** — то, что generic не выражает: end-to-end сверки, монотонность кумулятивов.
- **Unit-тесты** — *сложная SQL-логика* (joins, windows, multi-condition case, NULL-обработка), а не структура.

**Правило de-duplication:** один и тот же инвариант ставим **только на одном слое**. Если `platform` тестируется на source — на staging/intermediate/core не повторяем. Если `event_value_in_usd > 0 ⇔ in_app_purchase` стоит на staging — на source не дублируем. Статические факты о датасете (диапазон дат сэмпла, 50k/день) → документация, не тест.

### 2.3 DQS-фрейминг (5 dimensions)

Чтобы не получить «20 тестов на uniqueness и ноль на validity», каждый тест помечаем dimension'ом:

| Dimension | Что измеряет | Где ставим |
|---|---|---|
| Completeness | Null / missing rate на критических колонках | `not_null` |
| Consistency | Соответствие типов, формат, отсутствие смешанных типов; reconciliation | `unique_combination_of_columns`, end-to-end singular'ы |
| Validity | Значения в ожидаемом домене (диапазон, категория) | `accepted_values`, `accepted_range`, `expression_is_true` |
| Uniqueness | Нет дублей PK | `unique`, `unique_combination_of_columns` |
| Timeliness | Свежесть таймстемпов | `freshness` на source |

Цель: на каждом критическом грейне покрыты все 5 dimensions хотя бы одним тестом.

---

## 3. Текущее покрытие vs целевое

| Слой | Сейчас (gen) | Сейчас (sing) | Будет (gen) | Будет (sing) | Будет (unit) |
|---|---:|---:|---:|---:|---:|
| Source `raw.events` | 0 | 0 | **5** (4 not_null + 1 accepted_values) | 0 | — |
| Staging `stg_events` | 7 | — | 7 (–1 accepted, +1 device_category not_null) | — | 0 |
| Intermediate (3 view) | 9 | — | **5** (–4: trim) | — | 0 |
| `_utils/day_numbers` | 3 | — | 3 | — | — |
| Core `dim_users` | 5 | — | **6** (+1 not_null country_top5; –1 accepted_values platform) | — | **1** |
| Core `fct_user_daily` | 8 | — | **11** (+4: events≥1, engagement_sec≥0, n_purchases≥0, paying_flag↔gross_revenue; D0 sub-test) | — | **3** |
| Intermediate (`int_user_install`) | — | — | — | — | **1** |
| Reports (4 mart) | 30 | — | **~24** (–~7: trim not_null на coalesce'ных колонках; +1 cum_arppu invariant) | — | **3** |
| `tests/` (singular) | — | 6 | — | **9** (+3 by_platform/reconciliation, +1 fct↔dim cohort_date, –1 удалён as duplicate) | — |
| **Итого** | **62** | **6** | **~62** | **9** | **9** |

Эффект **не в количестве, а в распределении**:
- Core: с 13 → **18 generic + 6 unit = 24 тестов на 2 модели** = ~12 на модель.
- Reports: с 30 → **24 generic + 3 unit = 27 на 4 модели** = ~7 на mart.
- Per-model density: **core теперь толще per-модель**, как и должно быть — это source of truth для всех downstream витрин.

Уходим от дублей (единый owner per инвариант), закрываем три gap'а:
1. Source-контракт (не было).
2. Unit-тесты на сложной SQL-логике в core (не было).
3. Денормализация `cohort_date` в `fct_user_daily` (не покрыта generic'ами).

---

## 4. План добавлений

### 4.1 Source: `raw.events`

Цель — зафиксировать **контракт источника**: что должно быть в `raw.events` чтобы `stg_events` корректно собирался. Однократно, наверху пайплайна; ниже не дублируем.

**В `models/staging/_sources.yml`:**

| Тест | Колонка | Severity | DQS dim | Why |
|---|---|---|---|---|
| `not_null` | `user_pseudo_id`, `event_timestamp`, `event_name`, `platform` | error | Completeness | Source-контракт. Ловит upstream-сбой до того, как пострадает наш staging. |
| `accepted_values: [ANDROID, IOS]` | `platform` | error | Validity | Третье значение = новая product build. **Единственный accepted_values во всём pipeline** — `platform` ниже идёт пасс-тру, дублировать не нужно. |

**Singular в `tests/` — нет.**

Что **не делаем** (и почему):
- ~~`freshness`~~ — статичный публичный сэмпл 2018 года не «свежеет». В README зафиксировано как известная особенность датасета; на проде вернуть с `warn_after: {count: 1, period: day}` через `loaded_at_field: _LOAD_TIMESTAMP`.
- ~~`assert_source_app_id_platform_pairs`~~ — `accepted_values` на `platform` уже ловит «новую сборку». Связь `(platform, app_id)` 1:1 — отдельный тест избыточен. `app_id` тестируем на staging (там он top-level после промоута struct).
- ~~`assert_source_revenue_only_in_app_purchase`~~ — этот инвариант уже стоит на `stg_events` через `expression_is_true`. Дублировать на источнике = тратить две query на один контракт.
- ~~`assert_source_50k_per_event_date`~~ — артефакт публичного сэмпла, не инвариант. Зафиксировано в README как известная особенность; в `_sources.yml.description` короткая ссылка.
- `dbt_utils.unique_combination_of_columns` на источнике — есть на staging после dedup, повторять до dedup'а бессмысленно (там 207 дублей by design).

### 4.2 Staging: `stg_events`

| Действие | Тест | Why |
|---|---|---|
| keep | `unique_combination_of_columns(user_pseudo_id, event_timestamp, event_name)` | Подтверждает корректность rowid-anti-join дедупа на реальных 5.7M. |
| keep | `not_null` на `user_pseudo_id`, `event_timestamp`, `event_ts_utc`, `event_date_utc`, `event_name`, `platform` | Tier 1. |
| keep | `expression_is_true: event_value_in_usd is null or (event_value_in_usd > 0 and event_name = 'in_app_purchase')` | Tier 3, единственный критический инвариант. |
| **drop** | `accepted_values` на `platform` | Переезжает на source. `platform` пасс-тру → один тест на источнике достаточно. |
| **add** | `not_null` на `device_category` | Проверено: 0% null, 2 значения (`mobile`/`tablet`). |
| skip | `accepted_values` на `event_name` (37 значений) | Слишком хрупко. |
| skip | `accepted_values` на `country` (200+ значений) | Типичный fail mode «новая страна». |
| skip | `accepted_values` на `device_category` | Если `mobile`/`tablet` контракт важен — добавим, но 2 значения долго не меняются; сейчас не критично. |

### 4.3 Intermediate (3 view)

**Что эти тесты делали и зачем убираем большую часть:**

Изначально на intermediate стояли `unique` / `unique_combination_of_columns` на новом грейне (event → user или event → user-day) и `not_null` на ключевых полях. Цель — поймать join-баг локально, чтобы при сбое сразу знать «дело в intermediate, а не в марте».

На практике downstream покрытие строже:
- `dim_users.user_pseudo_id` уже `unique + not_null` → ловит баг в `int_user_install`.
- `fct_user_daily` имеет `unique_combination_of_columns(user_pseudo_id, activity_date)` + `relationships → dim_users` → ловит баг в `int_user_daily_*`.

То есть intermediate-тесты **не добавляют покрытия**, только дают чуть лучшую локализацию ошибки. Цена — лишние tests в каждом `dbt test`.

| Модель | Действие | Что остаётся |
|---|---|---|
| `int_user_install` | **trim** | Только `not_null` на `user_pseudo_id`, `cohort_date` (cheap, fast-fail). Убираем `unique` и `accepted_values` (дублируют `dim_users`). |
| `int_user_daily_activity` | **trim** | Только `not_null` на `user_pseudo_id`, `activity_date`. Убираем `unique_combination_of_columns` (дублирует `fct_user_daily`). |
| `int_user_daily_revenue` | **trim** | Аналогично. |

### 4.4 Marts/core: главный фокус

#### `dim_users` — generic

| Тест | Severity | DQS dim | Why |
|---|---|---|---|
| keep `unique` + `not_null` на `user_pseudo_id` | error | Uniqueness, Completeness | Tier 1. |
| keep `not_null` на `cohort_date`, `install_platform` | error | Completeness | По построению. |
| **add** `not_null` на `install_country_top5` | error | Completeness | Каждый юзер должен иметь либо страну из топ-5, либо `'Other'` — NULL = баг в CASE. |
| **add** `expression_is_true: events_total > 0` | error | Validity | Каждый юзер виден в источнике (cohort_date по построению). Ловит баг в `events_total` CTE. |
| **drop** `accepted_values` на `install_platform` | — | — | Покрыто на source (`platform` пасс-тру через staging → `int_user_install` → `dim_users`). |
| ~~`accepted_values` на `install_country_top5`~~ | — | — | **Не добавляем.** Список считается динамически в CTE; зависит от данных и может легитимно меняться. И unit-тест на fallback тоже не делаем — это тестирование динамики, цена/ценность плохая. |
| ~~`expression_is_true: cohort_date between …`~~ | — | — | **Не добавляем.** Это статический факт о датасете, а не инвариант модели. Документируем в `_sources.yml.description` и в `dim_users` description. |

#### `fct_user_daily` — generic

| Тест | Severity | DQS dim | Why |
|---|---|---|---|
| keep `unique_combination_of_columns(user_pseudo_id, activity_date)` | error | Uniqueness | Tier 1, sparse PK. |
| keep `relationships: user_pseudo_id → dim_users` | error | Consistency | Tier 1, ни одного «осиротевшего» события. |
| keep `not_null` на PK-колонках, `cohort_date`, `day_number` | error | Completeness | — |
| keep `expression_is_true: day_number >= 0` | error | Validity | См. ниже про дубли. |
| keep `expression_is_true: gross_revenue >= 0` | error | Validity | Tier 3. |
| **add** `expression_is_true: events >= 1` | error | Validity | Sparse-инвариант: строка существует ⇒ был >= 1 event. |
| **add** `expression_is_true: paying_flag = (gross_revenue > 0)` | error | Validity | Производное поле; защита от дрейфа. |
| **add** `expression_is_true: engagement_sec >= 0` | error | Validity | Sanity на агрегат; coalesce(... , 0) в SQL → 0 минимум. |
| **add** `expression_is_true: n_purchases >= 0` | error | Validity | Sanity на coalesce'ный счётчик. |
| **add** `expression_is_true: (n_purchases > 0) = paying_flag` | error | Validity | Внутренняя консистентность: платящий день ⇔ были покупки. |

#### Унификация singular vs generic

Сейчас два теста дублируются с generic'ами на тех же колонках:

| Singular | Дубликат | Решение |
|---|---|---|
| `assert_no_activity_before_cohort.sql` | `expression_is_true: day_number >= 0` | **Удалить singular** (generic покрывает дешевле). |
| `assert_day_number_arithmetic.sql` | — | **Оставить** (проверяет связь двух колонок, generic так не умеет). |

### 4.5 Marts/reports — бизнес-инварианты

Изначально на reports густо лежали `not_null` на всех output-колонках. Часть из них покрыта **по построению** SQL'ом (`coalesce(..., 0)`, `count(*) GROUP BY`, window-функции над non-null входами) — тестировать «никогда не NULL» там, где SQL гарантирует это синтаксически, low-signal. Триммим.

| Mart | Действие | Что остаётся / меняется |
|---|---|---|
| `mart_retention_overall` | trim + add | **drop** `not_null` на `retained_users` (coalesce'ный) и `cohort_size` (count(*) → не NULL). **Keep**: unique_combo, not_null на PK (`cohort_date`, `day_number`), `retention_pct ∈ [0,1]`, `retained ≤ cohort`. D0=1.0 уже покрыт `assert_d0_full_retention.sql`. |
| `mart_retention_by_platform` | trim + add | Аналогично + **keep** not_null на `install_platform`. **add singular** `assert_d0_full_retention_by_platform.sql`. |
| `mart_revenue_overall` | trim + add | **drop** `not_null` на `cohort_size`. **Keep** PK + бизнес-инварианты + accepted_values. **add generic** `expression_is_true: cum_arppu is null or cum_arppu = cum_revenue / cum_paying_users` (производное поле). |
| `mart_revenue_by_platform` | trim + add | Аналогично. **add singular** `assert_cum_revenue_monotonic_by_platform.sql`. |

**Принцип:** на reports тестируем то, что **бизнес-логика** должна гарантировать (бизнес-инварианты, кумулятивы, реляции метрик), а не то, что **синтаксис** уже гарантирует (coalesce'ные нули, count(*) выходы). Структурную плотность держим в core.

### 4.6 Singular — итоговый список

**Новые файлы:**

| Файл | Что | DQS dim |
|---|---|---|
| `assert_paying_users_reconciliation.sql` | `count(distinct user_pseudo_id)` платящих в `mart_revenue_overall` D30 = в `stg_events` фильтр `in_app_purchase` + D0..D30 окно. End-to-end замыкание. | Consistency |
| `assert_d0_full_retention_by_platform.sql` | D0 retention = 1.0 в by_platform mart. | Validity |
| `assert_cum_revenue_monotonic_by_platform.sql` | Монотонность cum_revenue в by_platform. | Validity |
| `assert_fct_dim_cohort_date_consistency.sql` | `fct_user_daily.cohort_date == dim_users.cohort_date` для каждого `user_pseudo_id`. Закрывает gap: денормализованная `cohort_date` в fct может разойтись с источником (dim_users) при баге в join. Generic-тесты на колонке смотрят только саму fct и этого не ловят. | Consistency |

**Удалить:** `assert_no_activity_before_cohort.sql` (см. §4.4).

**Не пишем** (источник): `assert_source_app_id_platform_pairs`, `assert_source_revenue_only_in_app_purchase`, `assert_source_50k_per_event_date` — см. §4.1, заменены `accepted_values`/`expression_is_true` на staging либо документацией.

### 4.7 Unit-тесты

**Кандидаты по убыванию ценности:**

| Модель | Что unit-тестировать | Почему unit, а не data test |
|---|---|---|
| **`fct_user_daily`** | (1) Sparse-семантика: юзер активен в день D и купил в этот же D → одна строка, `gross_revenue > 0`, `paying_flag = true`. (2) Юзер активен в D, не купил → одна строка, `gross_revenue = 0`, `paying_flag = false`. (3) Day_number arithmetic: mock `cohort_date='2018-06-12'`, `activity_date='2018-06-19'` → `day_number = 7`. | join + COALESCE + производное поле в детерминированных условиях. data test увидит «всё ок в среднем», unit — что **именно эта** строка собралась правильно. |
| **`dim_users`** | (1) p99-граница: на mock из 4 юзеров → outlier только тот, что строго > p99 (не ≥). | Тестируем строгое неравенство в одной строке кода; data test эту границу не зафиксирует. |
| **`int_user_install`** | (1) `is_reinstall = bool_or(previous_first_open_count > 0)`: юзер с `previous_first_open_count = 5` → `is_reinstall=true`; юзер без `first_open` → `false` (NULL-safe). | bool_or vs max — лёгкая регрессия при рефакторинге; NULL-семантика. |
| **`mart_revenue_overall`** | (1) `cum_arppu` NULL handling: когорта без платящих → `cum_arppu = NULL` (а не 0/0 ошибка). (2) Cumulative correctness: mock 3 дня по $1 → `cum_revenue = $1, $2, $3`, `cum_arpu = $1/N, $2/N, $3/N`. (3) Densification: когорта в которой никто не дошёл до D5 → строка существует, `gross_revenue=0`, `paying_users=0`. | Window-функции с NULL-edge case + кумулятивы — самый рисковый код в репо. Один баг в `case when sum() = 0 then null else …` ломает все когорты, но в текущих данных воспроизводится в < 1% случаев — unit ловит детерминированно. |

**Не unit-тестируем:**
- `stg_events` — простая проекция и dedup; data test `unique_combination_of_columns` подтверждает корректность дедупа на реальных 5.7M.
- Intermediate views — простые `GROUP BY`, нет сложной логики.
- `mart_retention_*` — densify + count distinct, единственный сложный кусок (D0 = 1.0) уже покрыт singular'ом.
- `mart_revenue_by_platform` — копия `_overall` с дополнительным `partition by`; unit на `_overall` покрывает шаблон.
- `day_numbers` — `generate_series`. Тестировать встроенную функцию = anti-pattern по скиллу.

**Где живут unit-тесты:**
- YAML: `models/marts/core/_unit_tests.yml`, `models/marts/reports/_unit_tests.yml` (отдельный файл для удобочитаемости).
- Fixtures: `dict` формат inline — минимум кода. CSV/SQL-фикстуры не нужны.
- Запуск: `dbt build --select fct_user_daily dim_users mart_revenue_overall` (build → unit-тесты → материализация → data tests).
- В CI / `make build`: остаются включёнными по умолчанию (на DuckDB цикл < 5 сек). На BQ-проде вынесут через `--exclude-resource-type unit_test`.

### 4.8 Drift-watchers — отложено

Из `eda_tests.md` §F. **Не делаем сейчас.** Кандидаты на потом (если возникнет потребность мониторить дрейф):

- Доля 1-day-юзеров (baseline 52%).
- Доля `device_os IS NULL` (baseline 16%).
- Доля `traffic_medium = '(none)'` (baseline 75%).

---

## 5. Что осознанно НЕ делаем

- **Не покрываем intermediate** ничем кроме `not_null` на PK — те же инварианты строже сидят в `marts/core`.
- **Не дублируем accepted_values по слоям** — `platform` живёт на source, ниже только пасс-тру.
- **Не пишем source-singular'ы** на «50k/день», на «(platform, app_id) пары», на revenue-инвариант — это либо статика (документация), либо покрыто `accepted_values`/`expression_is_true` соседнего слоя.
- **Не тестируем динамические артефакты** (`install_country_top5`, диапазон `cohort_date`) — они зависят от данных и легитимно меняются. Документируем; крайние случаи (fallback в `'Other'`) — через unit-тест.
- **Не пишем тесты на `_utils/day_numbers`** — это `generate_series`, тестировать встроенную функцию = Tier 4.
- **Не пишем unit-тесты на staging-дедуп** — реальные 5.7M строк являются «фикстурой», data test `unique_combination_of_columns` адекватен.
- **Не запускаем `data_profiler.py` / `outlier_detector.py`** из `data-quality-auditor` — скрипты CSV-only, дублируют EDA. DQS-framing берём, скрипты — нет.
- **Не привязываем тесты к dashboard-метрикам** (Part 4) — это вне scope тестового слоя.


---

## 6. Verification (как поймём, что сделано)

1. `dbt build` зелёный — старая планка плюс новые тесты в выводе.
2. `dbt list --resource-type unit_test --resource-type test` показывает все новые тесты.
3. `dbt build --select fct_user_daily dim_users mart_revenue_overall` (с unit-тестами) проходит.
4. Каждый новый тест в `_models.yml` / singular-файлах сопровождён DQS dimension и однострочной rationale.
5. README §test-strategy указывает на этот файл как на источник истины.

---

## 8. Спорные моменты — резолюция

| # | Что | Решение |
|---|---|---|
| 1 | Source freshness на статичном DuckDB-сэмпле | Не декларируем. Особенность датасета (статичный публичный сэмпл) фиксируем в README; на проде вернуть `freshness` с `loaded_at_field: _LOAD_TIMESTAMP`. |
| 2 | `assert_no_activity_before_cohort.sql` | Удалить (есть дешёвый generic). |
| 3 | `device_category` not_null | Добавляем — проверено: 0% null. |
| 4 | Drift-watchers | Отложить. |
| 5 | Source-singular'ы (3 шт.) | Не пишем — заменены `accepted_values`/`expression_is_true` на staging либо документацией. |
| 6 | `accepted_values` на каждом слое | Только на source (`platform`) + на staging (`device_category` пока без него). Не дублируем по слоям. |
| 7 | `accepted_values` на `install_country_top5` | Не делаем — список динамический. Корректность fallback в `'Other'` проверим unit-тестом. |
| 8 | `expression_is_true: cohort_date between …` | Не делаем — это факт о данных, документируем. |
| 9 | Intermediate-тесты | Триммим до `not_null` на PK; уникальность покрыта downstream. |
| 10 | Распределение density core vs reports | Реверснули: core стал ~12 тестов/модель, reports ~7/mart. Reports trim'нули по `not_null` на `coalesce(..., 0)`-колонках (синтаксис уже гарантирует non-null). На core добавили **business invariants** (`events ≥ 1`, `n_purchases ≥ 0`, `(n_purchases > 0) = paying_flag`, `events_total > 0`, `not_null` на `install_country_top5`) и закрыли gap с денормализованной `cohort_date` через `assert_fct_dim_cohort_date_consistency.sql`. |
