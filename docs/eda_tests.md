# Бизнес-проверки качества данных

Список идей тестов для dbt-проекта (Parts 3–4 ассайнмента), сгруппированный по намерению. Базовые числа и аномалии, на которые опираются проверки, лежат в `docs/data_exploration.md` — этот файл не дублирует EDA, а превращает её выводы в конкретные инварианты.

Условные обозначения:

- **(todo)** — уже перечислено в `todo.md` §Tests; здесь — для полноты картины и контекста.
- **warn** — тест-сторож, не fail/pass: фиксируем baseline и алертим на дрейф.
- Без пометки — новые предложения помимо `todo.md`.

---

## A. End-to-end сверки (закрытие петли)

Эти тесты ловят потерю данных в трансформации между сырьём и мартами.

- **Revenue total**: `SUM(gross_revenue)` в `mart_revenue_by_cohort` == `SUM(event_value_in_usd)` в `stg_events`. Если расходится — деньги потеряли где-то по дороге.
- **Paying users total**: `COUNT(DISTINCT user_pseudo_id)` с покупкой в марте == то же самое в `stg_events`. Потеря пользователей в трансформации.
- **Cohort size sum**: `SUM(cohort_size)` по всем `cohort_date` в `mart_retention_by_cohort` == `COUNT(*)` в `dim_users`. Никого не потеряли при когортизации.

## B. Структурные синглтоны (алерт «появилось третье»)

Сейчас данные имеют ряд жёстких 1- или 2-значных инвариантов. Полезно зафиксировать их тестом — третье значение = breaking change в источнике.

- `user_ltv.currency` = `'USD'` (сейчас единственное значение; новая валюта потребует конвертации).
- `(platform, app_info.id)` принимает ровно две пары: `(ANDROID, com.labpixies.flood)` и `(IOS, com.google.flood2)`. Третья = новый билд продукта.
- `event_value_in_usd > 0` только на `event_name = 'in_app_purchase'` (сейчас 27/27). Новое событие с деньгами = новый источник revenue, надо переосмыслять revenue-март.
- `event_params.level` хранится только в `int_value` или `double_value`. Третий слот = ломается coalesce в staging.
- `stream_id` ↔ `platform` остаётся 1:1.

## C. Когортные инварианты

- **(todo)** `retained_users ≤ cohort_size` для каждой `(cohort_date, day_number)`.
- **(todo)** В `(cohort_date, day_number = 0)` строке: `retention_pct = 1.0` и `retained_users = cohort_size`.
- **Нет активности до своей когорты**: `activity_date >= cohort_date` для каждой строки `fct_user_daily`.
- **Арифметика дня**: `day_number = activity_date - cohort_date` (не считается отдельно — проверяется как инвариант).
- **Нет «призраков» в dim_users**: каждый `user_pseudo_id` из `dim_users` имеет ≥ 1 запись в `fct_user_daily` на `day_number = 0` (он же активен в день своей когорты по построению).
- **(todo)** `cohort_date` ∈ окно `raw.events` (2018-06-12 … 2018-10-03).

## D. Монотонность кумулятивных метрик

Только для `cum_*` колонок — нек-кумулятивный `retention_pct` может колебаться по day_number.

- `cum_arpu` неубывающа по `day_number` внутри одной `cohort_date`.
- `cum_paying_users` неубывающа.
- `cum_revenue` неубывающа.

## E. Sanity на сырьё / сэмпл

- **50 k/день ровно**: `COUNT(*)` по каждому `event_date` в `raw.events` = 50 000. Сейчас это факт; как гард на refresh — изменится, значит источник изменился.
- **Покрытие дат сплошное**: 114 различных `event_date` без пропусков.
- `user_pseudo_id` не пустой и не пустая строка (нулевая защита от мусора).
- `event_value_in_usd >= 0` всегда; `user_ltv.revenue >= 0` всегда.
- **Дедуп**: `(user_pseudo_id, event_timestamp, event_name)` уникален **после** dedup-шага в staging. Если 0.004 % > 0 — пропустили dedup.

## F. Drift-watchers (warn)

Это не «pass/fail» тесты, а warn-уровневые — фиксируем baseline сейчас, наблюдаем сдвиг.

- Доля 1-day users — сейчас 52 % (7 856 / 15 175). Рост = сэмпл смещён в сторону «прохожих».
- Доля `device.operating_system = 'NaN'` — сейчас ~16 % событий / ~16 % пользователей.
- Доля `(direct)/(none)` в `traffic_source.medium` — сейчас 75 %.
- Доля `previous_first_open_count > 0` среди `first_open` — сейчас 3.7 % (161 / 4 319). Рост = больше реинсталлов.
- Размер «левоцензурированного» первого дня окна — сейчас 449 пользователей на 2018-06-12 (по построению они все «новые»). Резкое изменение = окно сместилось.

## G. Бизнес-логика f2p (опциональная, нужно подтвердить с продуктом)

- `level_complete_quickplay` без предшествующего `level_start_quickplay` у того же пользователя — нарушение игрового флоу. Сейчас 191 k complete на 523 k start — выглядит ОК, но строгая инвариант «complete после start» можно протестировать сингулярно.
- **(todo)** `paying_users <= cohort_size`.

---

## Где имплементировать что

- **Generic-тесты в `_models.yml`** — `unique`, `not_null`, `accepted_values`, `relationships`, `dbt_utils.expression_is_true`. Покрывают большую часть §A (через `expression_is_true`), §B (через `accepted_values` / `expression_is_true`), §C (большую часть), §E (`unique`, `not_null`).
- **Singular-тесты под `tests/`** — то, что не выражается через generic: §A end-to-end сверки, §C «нет активности до когорты», §D монотонность, §F при желании fail-strict.
- **Warn-уровень / QA-мартель** — §F drift-watchers лучше сделать как `tests/` с `severity: warn` или вынести в отдельный `mart_data_quality_metrics` для дашборда.
