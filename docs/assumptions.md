# Part 2 — Продуктовая постановка и допущения

Документ фиксирует, как расплывчатый запрос продакта превращается в измеримое ТЗ: что считаем, на каком грейне, какие границы выбраны и почему именно так. Все цифры и факты, на которые опираемся ниже, лежат в [`docs/data_exploration.md`](data_exploration.md) — этот файл не дублирует EDA, а превращает её выводы в продуктовые решения.

---

## 1. Что попросил продакт и что мы будем делать

> «Нам надо понять, как себя ведут новые игроки в первые дни. Хотим видеть retention, понимать монетизацию по когортам. Сделай нам простой дашборд, чтобы я мог сам туда заходить и смотреть.»

Переформулировка в измеримых терминах:

- **Юнит анализа** — когорта новых установок (cohort_date = первый день, когда `user_pseudo_id` появился в окне выборки).
- **Retention** — для каждой когорты доля игроков, активных на день `N` после установки (`day_number = 0..30`), где «активен» = эмитировал ≥ 1 любое событие в этот день.
- **Monetization** — для тех же `(cohort_date, day_number)`: cumulative revenue, ARPU, ARPPU, доля платящих.
- **«Простой дашборд»** — BI-слой собирается из готовых mart-таблиц без window-функций или сложных join'ов. Грейн витрин совпадает с грейном чартов; срезы и фильтры реализованы как обычные колонки.

Таким образом задача распадается на два mart'а с одинаковой осью `(cohort_date, day_number)` и общим набором срезов — это и есть скелет будущих витрин (см. §4).

---

## 2. Зафиксированные допущения

Каждое решение с одной строкой обоснования. Где применимо — ссылка на раздел EDA.

| # | Решение | Ответ | Почему |
|---|---|---|---|
| 1 | **Identity** | `user_pseudo_id` | `user_id` 100 % NULL, `ga_session_id` всегда отсутствует. Это единственный 100 %-покрытый стабильный ключ. См. EDA §Identifier model. |
| 2 | **Cohort anchor** | `cohort_date = min(event_date_utc) per user_pseudo_id` | `user_first_touch_timestamp` врёт у 97 % пользователей; `first_open` event есть только у 28 %. Только «первое наблюдённое событие» даёт 100 % покрытие. См. EDA §Identifier model. |
| 3 | **Date axis** | UTC из `event_timestamp` (`event_date_utc`); сырой `event_date` оставляем только для сверок | Локальный TZ (`event_date`) и UTC (`event_timestamp::date`) расходятся на 34 % строк. Один якорь во всём проекте, чтобы не плыли числа. |
| 4 | **Cohort grain** | Дневные когорты как базовый грейн mart'а; недельная агрегация — на стороне BI | Мелкий грейн обратимо роллапится; крупный — нет. |
| 5 | **Window length** | D0–D30, ключевые маркеры на дашборде: D0 / D1 / D3 / D7 / D14 / D30 | F2P-стандарт. Окно сэмпла 114 дней → даже последняя дневная когорта от 2018-09-03 имеет полный D30 в данных. |
| 6 | **Activity definition** | Активный = эмитировал ≥ 1 любое событие в этот день | Самое инклюзивное и стабильное; `session_start` есть только у 81 % пользователей, `ga_session_id` пуст. Узкое определение оставляем как возможный future slice. |
| 7 | **Retention type** | Classic D-N (активность ровно в день N), не rolling | F2P-канон, читается тривиально, BI рисует cohort-triangle без window-функций. |
| 8 | **Left-censored первая когорта** | (a) когорта 2018-06-12 **остаётся** в марте, но в дашборде помечается флажком «left-censored»; (b) пользователи с `cohort_date = 2018-06-12` исключаются из агрегатных KPI типа «средний D7 retention» | Все игроки 2018-06-12 — «новые» по построению (сэмпл начинается с этого дня), что раздувает первую когорту. Терять 449 пользователей жалко; молчать о них — врать. |
| 9 | **Re-installs** | Не вычитаем; флажок `is_reinstall` (по `previous_first_open_count > 0`) в `dim_users` — продукт сам решает, фильтровать ли | 161 случай (3.7 % от тех, у кого есть `first_open`); тихо лечить рискованно. |
| 10 | **Revenue source** | `event_value_in_usd` на `in_app_purchase` для атрибуции к когорте; `user_ltv.revenue` не используем в cohort-revenue | LTV — sticky-память: включает покупки до окна, которые нельзя attribute к нашему `cohort_date`. См. EDA §Monetization. |
| 11 | **Currency** | Всё в USD, без конвертации | `event_value_in_usd` уже USD-конвертирован Firebase'ом; `user_ltv.currency` всегда `USD`. |
| 12 | **Monetization metrics** | На `(cohort_date, day_number)`: `paying_users`, `cum_revenue`, `cum_arpu` (revenue / cohort_size), `cum_arppu` (revenue / paying_users), `paying_share` (paying_users / cohort_size) | Стандартный 4-pack для F2P cohort-monetization. |
| 13 | **Sample disclaimer** | На каждой странице дашборда — footnote «50k events/day public sample, числа относительные» | Сэмпл 50 000/день режет cohort sizes; абсолютные значения нерепрезентативны. EDA §Source and grain. |
| 14 | **Slices (dimensions)** | `platform` (Android/iOS), `country` (Top-5 + Other), `traffic_medium` (direct / organic / paid) | Чистые, не разрежают данные в кашу. Drilldown по paid-кампаниям не делаем — < 1 % трафика. |
| 15 | **Filters** | `cohort_date` range + те же три среза | Минимум, чтобы продакт мог сравнить когорты по периоду или по платформе. |
| 16 | **Bot/quality exclusion** | Не фильтруем; флажок `is_outlier_events` в `dim_users` для `events > p99` (≈ 5 541) — дашбордер сам решает | Явных ботов нет; max 102 503 events на пользователя подозрительно, но не повод тихо вычистить. |

### Что сознательно НЕ делаем сейчас

- **Сессионные метрики** — `ga_session_id` всегда пуст; реконструкция через `session_start` дала бы 81 %-покрытие, не стоит сложности на этой итерации.
- **Когортный funnel по геймплею** — продакт не просил «прохождение уровней по когорте»; это отдельная задача.
- **A/B-разрезы** (`firebase_exp_*`) — не озвучены в брифе; добавляются тривиально как ещё одна dimension в `dim_users`, если придёт запрос.
- **Прогноз LTV / predicted retention** — не ML-задача.

---

## 3. Открытые вопросы к продакту

Решения зафиксированы, но эти места стоит проверить «вживую» при первой возможности. Дублируются в `README.md` §6 «Вопросы, которые я задал бы».

1. **Что такое «новый игрок»** — впервые увиденный за всё время сэмпла, или впервые после конкретной маркетинговой кампании? Сейчас — первое.
2. **D7 или D30** — достаточно ли D7 для «первых дней», или нужны длинные хвосты? Сейчас — D30 как верхняя граница.
3. **Активный = что именно** — любое событие, `session_start`, или строго геймплей-событие (`level_start_*`)? Сейчас — любое событие.
4. **Re-installs** — считать как новую когорту, склеивать с первой установкой, или вычеркивать? Сейчас — считаем как новую, флажком даём фильтрацию.
5. **BI-инструмент** — Metabase / Superset / Looker / Tableau? Влияет на форму mart'ов: некоторые BI лучше работают с long-form, некоторые — с wide-form.
6. **Latency** — дневное обновление окей, или нужен real-time / near-real-time? Сейчас — ориентир на ежесуточный refresh (см. Airflow-скетч в Part 6).
7. **Окно ретеншна для платящих** — считать ARPPU только по тем, кто заплатил в первые N дней, или по всем платящим в когорте за всё время? Сейчас — по всем платящим в окне D30.

---

## 4. Карта «допущение → витрина»

Чтобы Part 3 строил mart'ы без возврата к этим вопросам:

| Допущение | Где материализуется |
|---|---|
| #1, #2, #9, #16 — identity, cohort anchor, флажки | `dim_users(user_pseudo_id, cohort_date, install_platform, install_country, install_traffic_medium, is_reinstall, is_outlier_events)` |
| #3, #6 — UTC date, любое событие = активность | `int_user_daily_activity(user_pseudo_id, activity_date, events, engagement_sec)` — один ряд на user-day |
| #10, #11 — revenue из `event_value_in_usd`, USD | `int_user_purchases_daily(user_pseudo_id, activity_date, gross_revenue, n_purchases, paying_flag)` |
| #4, #5, #7 — daily cohorts, D0–D30, classic D-N | `mart_retention_by_cohort(cohort_date, day_number, [slices...], cohort_size, retained_users, retention_pct)` |
| #12 — F2P monetization 4-pack | `mart_revenue_by_cohort(cohort_date, day_number, [slices...], paying_users, cum_revenue, cum_arpu, cum_arppu, paying_share)` |
| #14, #15 — slices/filters | Колонки `platform`, `country_top5`, `traffic_medium` дублируются в обеих витринах для фильтрации без join'ов на стороне BI |
| #8, #13 — left-censored cohort, sample disclaimer | Метаданные дашборда (footnote, флажок); в марте данные присутствуют |

---

## 5. Контекст / источники

- [`docs/data_exploration.md`](data_exploration.md) — все фактические числа и аномалии, на которые опираются решения выше.
- [`docs/eda_tests.md`](eda_tests.md) — список бизнес-инвариантов, которые в Part 3 переезжают в `_models.yml` (cohort_size sum-checks, монотонность cum-метрик, end-to-end revenue reconciliation).
- [`TEST_ASSIGNMENT.md`](../TEST_ASSIGNMENT.md) — оригинальная постановка от продакта (Part 2).
