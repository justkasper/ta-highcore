# Free-form report — ответы на вопросы Части 1

Сжатые ответы по трём пунктам ассайнмента. Полные таблицы и числа — в `docs/data_exploration.md`, на разделы которого здесь идут ссылки.

---

## 1. Структура данных

**События** — 37 различных `event_name`. Грейн: одна строка на одно эмитированное Firebase-событие. Топ по объёму (`docs/data_exploration.md` §Event vocabulary):

- `screen_view` 2.25 M / 14.1 k users
- `user_engagement` 1.36 M / 13.6 k — несёт `engagement_time_msec`
- `level_*_quickplay`, `post_score` — игровая телеметрия
- `session_start` 74 k / 12.3 k
- `first_open` 4.3 k / 4.3 k — присутствует не у всех
- `in_app_purchase` 27 / 24 — единственное событие, у которого `event_value_in_usd > 0`

**Nested-поля**:

- `event_params` и `user_properties` — оба `LIST<STRUCT<key, value{string|int|double|float|set_timestamp_micros}>>`. 12 ключей в event_params в активном использовании, 25 ключей в user_properties (полные таблицы — §`event_params` keys и §`user_properties` keys). Нужное под-поле `*_value` зависит от ключа, у `level` смешанный тип (10 % `int_value`, 90 % `double_value`) — coalesce при извлечении.
- `device`, `geo`, `app_info`, `traffic_source` — обычные `STRUCT`, доступ через точку (`device.category`, `geo.country`, …).
- `user_ltv` — `STRUCT(revenue, currency)`; `currency` всегда `USD`.
- `event_dimensions` — `STRUCT`, 100 % NULL → дроп.

**Пользовательские идентификаторы** (§Identifier model):

- `user_pseudo_id` — единственный стабильный: 100 % покрытие, нет null/empty, ни один пользователь не пересекает платформы. Это правильный ключ когорты.
- `user_id` — 0 / 5.7 M, всегда NULL.
- `ga_session_id` — 0 / 5.7 M, никогда не выставлен; сессии из этого поля не восстановить.
- `user_first_touch_timestamp` — 100 % покрытие, но врёт у 97 % пользователей (см. §2).
- `first_open` event — только у 28 % пользователей; из них 161 реинсталл.

## 2. Аномалии

(§Data quality issues — там же таблица из 13 пунктов)

- **Жёсткая выборка 50 000 событий/день** ровно — 114 дней × 50 k = 5.7 M. Не баг, артефакт публичного BigQuery-сэмпла, но критичен: размеры когорт занижены, читать только относительно.
- **TZ-skew**: `event_date` (локальная TZ, `YYYYMMDD`) и `event_timestamp::date` (UTC) расходятся на 1 935 518 строк (34 %).
- **`uft` ≠ первое наблюдённое событие у 14 701 / 15 175 (97 %)**:
  - 10 726 (71 %) — `uft` *до* окна (legacy-пользователи, чей реальный install вне сэмпла);
  - 3 975 (26 %) — `uft` *после* первого события (артефакт перезаписи `uft` поздним событием, вероятно `firebase_campaign`).
- **`first_open` partial**: 4 319 / 15 175 пользователей (28 %); 161 из них — реинсталлы (`previous_first_open_count > 0`).
- **207 дублей** по `(user_pseudo_id, event_timestamp, event_name)` (0.004 %) — мало, но ломает `unique`-тест на этом грейне.
- **`device.operating_system = 'NaN'`** строкой — ~337 k событий / ~2.4 k пользователей.
- **`event_dimensions`** 100 % NULL; **`stream_id`** 1:1 с `platform` — оба избыточны.
- **52 % пользователей** (7 856 / 15 175) видны ровно на одной дате — высокая доля «один день и больше нет».
- **`event_previous_timestamp ≥ event_timestamp`** на 2 994 строках — мелкая аномалия, downstream не используем.
- **`level` смешанного типа** (10 % int / 90 % double).
- **`traffic_source` сильно разрежен**: 75 % `(direct)/(none)`, 24 % `organic/google-play`, < 1 % paid — оборачивает ценность среза по install-source.

## 3. Как устроен поток (структурно, без продуктовых гипотез)

- Это **не полный поток событий, а сэмпл** публичной BigQuery-таблицы `firebase-public-project.analytics_153293282` (мобильная f2p-головоломка Flood-It!). Кап 50 k/день — ключевой структурный артефакт, на котором завязано всё.
- В одной таблице живут **две сборки одного продукта**: `com.labpixies.flood` (Android) и `com.google.flood2` (iOS). `platform` и `stream_id` дают одну и ту же 2-way раскладку, пользователи между сборками не пересекаются.
- **Один источник, без FK** (§Relationships). Единственные «join»-операции — распаковка `event_params` / `user_properties` в широкие колонки на слое staging.
- **Грейн — событие**; естественного однопольного PK нет, ближайший почти-уникальный кортеж — `(user_pseudo_id, event_timestamp, event_name)`, с 207 коллизиями.
- **Время живёт в двух системах**: локальная TZ (`event_date`, `YYYYMMDD`-строка) и UTC (`event_timestamp`, microseconds). Они расходятся на 34 % строк → нужно выбрать один якорь (рекомендую UTC; `event_date` оставить только для сверки с источником).
- **Идентичность держится на одном поле** — `user_pseudo_id`. Все альтернативные якоря когорты ломаются: `user_id` пуст, `ga_session_id` пуст, `uft` врёт у 97 %, `first_open` отсутствует у 72 %. Это форсирует якорь `cohort_date = min(event_date_utc) per user_pseudo_id`, и left-censored пользователи будут раздувать первый день окна (2018-06-12: 449 «новых», по факту это все, кто оказался в выборке в этот день).
- **Денежный сигнал тонкий и противоречивый**: `event_value_in_usd > 0` — 24 пользователя / 27 событий / $24.89 в окне (атрибутируется когорте); `user_ltv.revenue > 0` — 146 пользователей, причём 122 из них покупали *до* окна и в выборке самого события покупки нет, осталась только LTV-память. Поэтому для маркетинга когорты — `event_value_in_usd`, а не `_ltv_*`.
- **Кодировки/типы шумят**: смешанные value-типы в `event_params` (`level`), литерал `'NaN'` в `device.operating_system`, перезапись `uft` — типичный «грязный» Firebase-поток, требует нормализации в staging.
