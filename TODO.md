# Code review - dbt-проект

Ревью проведено через skill `using-dbt-for-analytics-engineering` (DAG/DRY guidelines, planning + writing-data-tests references). Предмет: 11 моделей в `models/`, 8 singular + 11 unit тестов, 3 макроса, конфиги (`dbt_project.yml`, `profiles.yml`, `packages.yml`).

Структура: P0 (нужно сделать), P1 (стоит), P2 (nice-to-have), что можно убрать, спорные точки для обсуждения.

---

## P0 - стоит закрыть до сдачи

### 1. `mart_retention_by_platform.cohort_size`: описание утверждает тест, которого нет

- [x] **Fixed** — добавлен `dbt_utils.expression_is_true: > 0` на `cohort_size`, описание переписано (`models/marts/reports/_models.yml`).

`models/marts/reports/_models.yml:117`:

```yaml
- name: cohort_size
  description: '... non-NULL by construction; tested as `> 0` on the row-set
                as a whole via the relationship `retained_users <= cohort_size`.'
```

Это неверно: `retained_users <= cohort_size` пройдёт и при `cohort_size = 0` (любое `retained_users >= 0`). На `mart_retention_overall` явно стоит `expression_is_true: > 0` на `cohort_size`, на by_platform нет, и описание это маскирует.

**Что сделать:** либо добавить `expression_is_true: > 0` на `cohort_size` в by_platform mart'е (симметрично overall), либо переписать описание честно: «not tested directly; trusted from upstream `count(*)`».

### 2. Расхождение `testing_plan.md` vs фактический код по локации `events_total > 0` теста

- [ ] **Skipped** per user. (Дополнительно: тест `events_total > 0` удалён в #20, расхождение становится моот.)

Из `docs/testing_plan.md` §4.4 план: добавить `expression_is_true: events_total > 0` в `dim_users`. Фактически тест стоит в `int_user_install._models.yml:58-60`, а в `dim_users` колонки `events_total` вообще нет (она потребляется только для derived `is_outlier_events`).

Это не баг кода (тест корректно живёт там, где есть колонка), но testing_plan.md описывает несуществующее намерение. Выбрать одно: (a) обновить `docs/testing_plan.md` и указать актуальную локацию (`int_user_install`, не `dim_users`), либо (b) пробросить `events_total` в `dim_users` и перенести тест туда (избыточно: колонка downstream не нужна). Рекомендую (a).

### 3. Артефакты README ссылаются на файлы из других веток

- [ ] **Skipped** per user — стратегия слияния веток вне scope этого захода.

`README.md` §2.1, §3, §8 ссылается на `docs/data_exploration.md`, `models/staging/_raw_events__eda.md` (исходно `docs/eda_report.md`, теперь doc-блок к `raw.events`), `docs/eda_tests.md`, `docs/assumptions.md`. Эти файлы лежат на `feature/part-1-*` и `feature/part-2-*`, на текущей `feature/part-4-dashboard-sketch` их нет.

В шапке README есть warning-блок об этом, но всё равно остаётся вопрос стратегии слияния веток перед сдачей: (a) merge всех `feature/part-N-*` в `main` (ссылки рабочие), (b) cherry-pick только финальных артефактов в одну ветку, (c) оставить как есть и предупредить ревьюера. Рекомендую (a). Без слияния половина ссылок в README 404, для ревьюера это первое, что бросится в глаза.

---

## P1 - улучшения, которые повышают защищённость

### 4. Нет теста, что revenue-день всегда имеет activity-день

- [x] **Fixed** — `tests/assert_revenue_days_are_activity_days.sql` (LEFT JOIN anti-pattern; ловит регрессию если фильтр `int_user_daily_activity` сузится).

Сейчас `fct_user_daily` строится через `from activity a JOIN users u ... LEFT JOIN revenue r`. То есть факт включает только `(user, day)` пары, где есть событие в `int_user_daily_activity`. Если у user'а есть `in_app_purchase` event в день, который не попал в `int_user_daily_activity`, доход потеряется.

Сейчас этого не бывает, потому что `int_user_daily_activity` группирует любые события по `event_date_utc`, а `in_app_purchase` это тоже event. Но инвариант неявный: никакой тест его не закрывает.

**Что сделать:** добавить singular `tests/assert_revenue_days_are_activity_days.sql`:

```sql
select user_pseudo_id, activity_date
from {{ ref('int_user_daily_revenue') }}
where (user_pseudo_id, activity_date) not in (
    select user_pseudo_id, activity_date
    from {{ ref('int_user_daily_activity') }}
)
```

Дешёвый, ловит регрессию если кто-то однажды сузит фильтр `int_user_daily_activity` (например, исключит system events).

### 5. `n_purchases` end-to-end reconciliation не покрыт

- [x] **Fixed** — `tests/assert_n_purchases_reconciliation.sql` (mart-side `sum(n_purchases)` vs stg-side `count(*) where event_name='in_app_purchase'` в окне D0..`var('max_day_number')`).

Есть `assert_revenue_reconciliation.sql` (доллары) и `assert_paying_users_reconciliation.sql` (платящие users), но не `SUM(n_purchases) in fct == COUNT(*) in_app_purchase в окне D0..D30`. Покрытие тонкое: `n_purchases` отличается от `paying_users` на 3 NULL-value события, это уже зафиксированная семантика, и забыть её легко при рефакторинге. Singular из 10 строк закроет.

### 6. `int_user_daily_*`: нет relationships → dim_users

- [x] **Fixed** — `relationships` тест с `severity: warn` на `user_pseudo_id` обоих `int_user_daily_*` моделей (`models/intermediate/_models.yml`).

`fct_user_daily` имеет `relationships: user_pseudo_id → dim_users`. Если в `int_user_daily_activity` появится orphan-user (например, после неполной перестройки `int_user_install`), fct это поймает через inner JOIN на `users`, orphan просто исчезнет, тест не сработает.

Не критично (данные не потеряются, orphan user в int не имеет смысла в принципе), но fast-fail удобнее. Trade-off: relationships тест вызывает `count(distinct ...)` на 5.7M строках; на DuckDB несекундно, на BQ потенциально costly. Решение: `severity: warn`, не error.

### 7. `int_user_install.attrs`: недетерминистичный tiebreak при равных microsecond + event_name

- [x] **Fixed** — добавлен детерминистичный tiebreak (`event_bundle_sequence_id NULLS LAST`, `event_server_timestamp_offset NULLS LAST`) в `attrs` ROW_NUMBER + `unique` тест на `int_user_install.user_pseudo_id`.

```sql
row_number() over (
    partition by s.user_pseudo_id
    order by s.event_ts_utc, s.event_name
) as rn
```

После dedup по `(user_pseudo_id, event_timestamp, event_name)` коллизия двух разных событий в одну microsecond возможна (разные `event_name`), но коллизия по `(timestamp + name)` нет. Документировано в `_models.yml:21` («alphabetical event_name tiebreak»). Корректно.

Однако если по каким-либо причинам два события с одинаковым `(timestamp, event_name)` всё-таки оказались в `stg_events` (баг dedup'а), `row_number` вернёт два rn=1, CROSS JOIN на `attrs.rn=1` даст 2 строки на user, `int_user_install.user_pseudo_id` потеряет уникальность.

**Что сделать:** добавить `not_null` + `unique` на `int_user_install.user_pseudo_id` (сейчас только `not_null`). Вообще на intermediate уникальность не дублируется (covered by dim_users), но именно здесь это fast-fail, который укажет на баг dedup'а непосредственно в этом слое. Альтернатива: добавить детерминистичный tiebreak (`event_bundle_sequence_id`, `_src_rowid`) в ORDER BY, устранит проблему в источнике вместо ловли в dim_users.

### 8. `assumptions.md` не на текущей ветке, не пересекается с `_sources.yml`

- [ ] **Skipped** per user — синхронизация at merge time, вне scope этого захода.

`_sources.yml` дублирует часть EDGE CASES, которые также описаны в `docs/assumptions.md` (живёт на части-2). Когда part-2 сольют, окажется два места с почти одинаковой информацией. Нужно решить: (a) `_sources.yml` оставить кратким (1-2 строки + `[see docs/assumptions.md]`), либо (b) `docs/assumptions.md` оставить, `_sources.yml` самодостаточный (текущее состояние). Сейчас (b), неплохо, но при изменении одной из версий нужно не забыть синхронизировать.

### 9. Cold-rebuild workaround вшит документально, не в коде

- [x] **Fixed** — `scripts/build_stg_batched.py` (Python wrapper, 114 чанков по `event_date`) + `make build-small` target + README обновлён. На ≥16 GB не нужно, `make build` остаётся стандартным путём.

`README.md` §1 и архитектура описывают батч по `event_date` как workaround OOM на 8 GB. Но `stg_events.sql` остаётся single CTAS. То есть на 8 GB-машине свежий клон проекта не запустится автоматически, нужен ручной workaround.

Варианты: (a) принять как known limitation (сейчас так), (b) реализовать через Python wrapper (`scripts/build_stg_batched.py`) и упомянуть в Makefile, (c) через dbt pre-hook + Jinja цикл (не помещается чисто, потребует custom materialization). Если приоритет «по README запускается с нуля на 8 GB», нужно (b). Если «работает на ≥16 GB и документирует ограничение», текущее состояние ОК.

### 10. `dbt_project.yml`: нет `query_comment`

- [x] **Fixed** — `query-comment` блок в `dbt_project.yml` (`node.unique_id | invocation_id | target.name`, `append: true`). На DuckDB не критично, на BQ упростит трассировку cost'а в `INFORMATION_SCHEMA.JOBS`.

Тонкий конфиг, нет `query_comment` для трассировки в warehouse-логах. Для DuckDB это не критично, но при миграции на BQ это первое, что добавит DataOps. Можно положить заранее:

```yaml
query_comment:
  comment: "{{ node.unique_id }} | {{ invocation_id }} | {{ target.name }}"
  append: true
```

### 11. `int_user_install` зависит от `top5_countries` CTE: динамика top-5 не воспроизводима в unit-тестах

- [x] **Superseded** — top-5 логика удалена целиком (см. секцию «top-5 countries» ниже): `top5_countries` CTE из `int_user_install.sql`, колонка `install_country_top5` из `int_user_install` + `dim_users`, упоминания в YAML и unit-тестах. Ни один mart её не консумит, scaffolding под потенциальный `mart_*_by_country` (off-scope).

Top-5 пересчитывается per refresh. Это документировано как осознанное решение, но если данные изменятся (новая страна в топе), изменятся значения в `dim_users.install_country_top5`, изменятся агрегаты в `mart_*_by_country` (если когда-то появится).

Не делать (это by design), но зафиксировать статический snapshot: добавить в `dim_users._models.yml` или в EDGE CASES комментарий «top-5 на дату последнего refresh: US/IN/JP/CA/GB» с датой. Сейчас это есть, но без даты, поэтому невозможно понять, актуально ли.

---

## P2 - nice-to-have

### 12. `mart_revenue_*`: `where f.day_number between 0 and 30` дублируется 4×

- [x] **Fixed** — `var('max_day_number')` (default 30) в `dbt_project.yml`; подставлено во все 4 mart'а + `_utils/day_numbers.sql` + 3 singular-теста (`assert_revenue_reconciliation`, `assert_paying_users_reconciliation`, `assert_n_purchases_reconciliation`). Расширение D-window теперь однострочный edit.

Можно вынести в макрос `{{ d_window() }}` или в var `{{ var('day_number_window') }}`. Сейчас 4 одинаковых литерала `between 0 and 30` (плюс ещё в `_utils/day_numbers.sql:1`, там `(0, 30)`). Если окно поменяется, нужно не забыть обновить во всех 5 местах. Для проекта на 11 моделей нерационально (lock-in макроса дороже повторения). Но если окно станет конфигурируемым, `var` оправдан.

### 13. `_utils/day_numbers`: не protected от расширения

- [x] **Fixed** — устранён вместе с #12. EDGE CASES и описание колонки `day_number` в `_utils/_models.yml` переписаны (упоминают `var('max_day_number')` как single source of truth).

Сейчас спина `0..30` хардкоднута в SQL. В `_models.yml:18-19` написано: «Extending to D60/D90 = one-line edit here, no downstream changes needed (every mart uses `between 0 and 30` filters which would also need updating)». Это противоречие: фраза говорит «one-line edit», но потом перечисляет ещё 4 места.

**Что сделать:** либо вынести `30` в `vars` (`max_day_number: 30`) и подставить везде, либо переписать описание честно («D-window is set in 5 places; keep them in sync»).

### 14. Описания нескольких column-level: restate column name

- [x] **Fixed** — переписаны описания: `int_user_install.first_event_name` (entry-funnel signal), `dim_users.first_event_name` (то же + ссылка на ad-hoc / `mart_*_by_first_event`), `mart_revenue_overall.cohort_size` (роль denominator'а для `cum_arpu` / `paying_share`).

skill `writing-documentation.md` запрещает «restate column name». Найдено:

- `int_user_install._models.yml:50`: `first_event_name` -> «Name of the user's first event in the sample.» (минимально, но по сути перефразирует имя; можно добавить ценность: «used to bucket by entry funnel: `first_open` is the canonical install signal, `screen_view` indicates re-entry without `first_open`»).
- `dim_users._models.yml:54-55`: `first_event_name` -> «Name of the user's first event.» (то же).
- `mart_revenue_overall._models.yml:181`: `cohort_size` -> «Number of users in this cohort.»

Не критично, большинство описаний толковые. Но 3-4 можно улучшить за 5 минут.

### 15. `mart_retention_*.retention_pct_trailing_4w_avg`: формула в 3 местах

- [ ] **Accepted as-is** — описание в `_models.yml` упоминает «28-cohort», макрос `trailing_avg(col, partition_by, days=28)` имеет default `28`. Sync через дефолт. Минор; править формулу = править default + 2 места в YAML, объём осознанный.

В описании mart'а (overall + by_platform) формула описана текстом, а в `retention_trailing_avg` макросе кодом. Если когда-нибудь поменяется на 2w или 8w, нужно править 3 места. Минор: сейчас описание говорит «28-cohort», макрос принимает `days=28` как default, синхронизировано через дефолт. ОК.

### 16. Нет smoke-теста на `dbt build` в CI

- [ ] **Skipped** per user.

`.github/workflows/` не наблюдается. Для тестового не страшно, но при реальном проекте нужен `make test-ci` job который запускает `make build` на свежем клоне.

---

## Что можно убрать / упростить

### 17. `int_user_install.attrs.first_event_name` слабо используется

- [x] **Reflected in docs** — описание `dim_users.first_event_name` теперь явно говорит «Currently NOT consumed by any mart — held for ad-hoc analytics and a possible future `mart_*_by_first_event` slice». То же для `int_user_install.first_event_name` (entry-funnel signal с указанием семантики `first_open` vs `screen_view`).

`first_event_name` пробрасывается до `dim_users.first_event_name`, но ни один mart его не консумит. Только для ad-hoc analytics. Не убирать (дёшево держать, ценно для discovery). Но если когда-то понадобится упростить, это первый кандидат.

### 18. `int_user_daily_activity.n_sessions_proxy` пробрасывается до `fct_user_daily`, нигде дальше не используется

- [x] **Reflected in docs** — описание `fct_user_daily.n_sessions_proxy` дополнено «Currently NOT consumed by any mart — passed through as exploration column for future per-session slices (e.g. session-quality cohorts)».

Аналогично выше: пробрасывается, но ни один mart не агрегирует. Описано как «available for future per-screen slices», то есть это exploration column, не production. Не убирать (пробрасывание легко стоит). Но в архитектурной карте честно отметить, что это «hold for future use, no current consumer».

### 19. Один из 6 unit-тестов в `marts/reports/_unit_tests.yml` borderline избыточен

- [x] **Fixed** — удалены оба null-on-first standalone unit-теста: `mart_retention_overall_trailing_avg_null_on_first_cohort` и `mart_revenue_overall_cum_arpu_trailing_avg_null_on_first_cohort`. Соответствующие partial-window тесты покрывают NULL-on-first в первой строке expected.

`mart_retention_overall_trailing_avg_partial_window_accumulates` покрывает (a) NULL on first cohort и (b) partial accumulation. А `mart_retention_overall_trailing_avg_null_on_first_cohort` уже покрывает (a) изолированно. То есть partial-window тест покрывает оба сценария за раз. NULL-on-first тест избыточен, можно удалить, оставить partial-window.

Trade-off: разделение даёт более ясный сигнал в diff-выходе («NULL сломалось» vs «accumulation сломалось»). Если ценится диагностика, оставить оба. Если строгий минимализм, удалить single-shot.

### 20. `events_total > 0` в `int_user_install`: Tier 3 для тривиально-истинного

- [x] **Fixed** — тест удалён, описание `events_total` дополнено объяснением «NOT directly tested — `events_total = count(*) per user` is `>= 1` by construction; a regression that broke this would already manifest as `unique` failures on `dim_users.user_pseudo_id`».

`events_total = count(*) per user` после `min(event_date_utc) per user`, причём cohort_date по построению есть, events_total ≥ 1 невозможно обнулить через корректный SQL. Тест ловит только баг типа «забыл GROUP BY», это поймает уже `unique` на `dim_users.user_pseudo_id`. Можно убрать как Tier 4 (low-value). Но цена держать 0.

---

## Спорные точки для обсуждения с архитектором

### A. `dim_users` практически прозрачный pass-through из `int_user_install` + 1 derived (`is_outlier_events`)

skill DRY-guideline: «before adding a model, ask if a column to existing model would suffice».

Можно ли упростить: удалить `int_user_install`, перенести его SQL в `dim_users` напрямую? Минус: исчезнет fast-fail слой, тестовая локализация хуже. Или удалить `dim_users`, переименовать `int_user_install` -> `dim_users`, добавить `is_outlier_events`? Минус: convention "intermediate vs marts" нарушается, BI ключевую таблицу будет звать `int_*`.

**Решение:** сохранить как есть. Это star-schema convention: `int_*` это staging для dimensions, `dim_*` финальные. Минус: лёгкая дубликация, плюс: стандартная архитектурная схема.

### B. `int_user_daily_activity` и `int_user_daily_revenue` - два почти-одинаковых тонких view, можно объединить

skill DRY-guideline: «Prefer adding column to existing model over adding new model».

Можно слить в `int_user_daily`:

```sql
select
    user_pseudo_id,
    event_date_utc as activity_date,
    count(*) as events,
    sum(coalesce(engagement_time_msec, 0)) / 1000 as engagement_sec,
    count(*) filter (where event_name='session_start') as n_sessions_proxy,
    sum(case when event_name='in_app_purchase' then event_value_in_usd end) as gross_revenue,
    count(*) filter (where event_name='in_app_purchase') as n_purchases
from stg_events
group by 1, 2
```

Плюсы: один view вместо двух; `fct_user_daily` упрощается (нет LEFT JOIN на revenue, revenue колонки уже в той же строке); грейн идентичный (`(user, activity_date)`), грузятся одни и те же 5.7M строк.

Минусы (как сейчас аргументирует `architecture.md` decision #6): разные источники: revenue **filter** по `event_name='in_app_purchase'`, сейчас фильтр живёт в `int_user_daily_revenue`, в объединённой модели становится inline `case when`-ом. Если когда-нибудь `int_user_daily_activity` получит дополнительный фильтр (например, исключить system events), а revenue должен считаться без него, придётся снова разделять.

**Решение:** сейчас trade-off в пользу разделения, обоснован в architecture. Но рекомендую перепроверить: для тестового объединение может быть проще и читабельнее. Если ревьюер спросит «зачем 2 view», ответ должен быть готов.

### C. `engagement_sec` нигде не консумится в reports

В `fct_user_daily` есть колонка, в mart'ах не выводится. То есть вся цепочка `stg -> int_activity -> fct -> ...` для `engagement_sec` не доходит до дашборда. Похоже на «оставлено на будущее». В `dashboard_sketch.md` упомянут extension по engagement quantiles. Не критично, но explicit лучше implicit: добавить в `fct_user_daily.engagement_sec` description строку «Currently not consumed by any mart, held for future engagement-quality slices».

### D. Стоит ли добавить `mart_*_by_country` сейчас или отложить?

`docs/dashboard_sketch.md` §4 явно пометил это как extension point: шаблон копируется, замена `install_platform -> install_country_top5`, ~10 минут.

Аргументы за «сделать сейчас»: демонстрирует, что архитектура реально расширяется без усилий; country slice продуктом запрашивается чаще traffic_medium.

Аргументы за «отложить»: YAGNI (продакт не запросил); добавляет +2 mart'а к проекту, больше тестов, больше доков, больше поверхности для ревью.

**Рекомендация:** добавить, если ревью делается на тестовое (показать pattern, +1 балл за «легко расширяется»). Не добавлять, если delivery в работающую команду (YAGNI).

### E. Скилл `dbt-docs` vs скилл «генерация staging-моделей из схемы»

В ТЗ перечислены 5 примеров скиллов; выбран dbt-docs. Альтернативы: skill «discover new source» (был бы кстати для Part 1, но не показывает dbt-конкретики); skill «scaffold staging from schema» (самый востребованный в дневной AE-работе, но сложнее правильно реализовать).

`dbt-docs` выбран как показавший себя в части 3. Защита: «документация самый частый источник `dbt docs`-долга». ОК-ная защита, но если ревьюер спросит «почему не более продакшен-ценный скилл», ответ должен быть готов.

---

## Что НЕ требуется

(Перечислил, чтобы было видно: рассматривал и отклонил.)

- Расширение source-тестов (`accepted_values` на `country` / `event_name` / `device_category`): слишком хрупко (см. testing_plan §4.2).
- Drift-watchers (доля 1-day-юзеров, traffic medium share): в testing_plan §4.8 явно отложено.
- Семантический слой dbt: переусложнение для тестового на 2 mart'ах × 2 slices.
- `dbt_expectations` / `dbt_meta_testing`: `dbt_utils` + singular'ы покрывают всё.
- incremental на `fct_user_daily`: на DuckDB 5.7M строк это секунды; на BQ `production_target_config` уже описан в `_models.yml`.
- Snapshot моделей: нет slowly-changing dimensions с историей в этом проекте.

---

## Сводка по приоритетам

| Уровень | Кол-во | Время на закрытие |
|---|---|---|
| P0 (до сдачи) | 3 | ~30 мин |
| P1 (production-ready) | 8 | ~2-3 часа |
| P2 (nice-to-have) | 5 | ~1-2 часа |
| Удалить/упростить | 4 (опционально) | ~30 мин |
| Спорные (обсуждение) | 5 | ревью с product/lead |

**Минимум перед сдачей:** P0 #1, #2, #3.

**Максимум разумного:** + P1 #4, #5, #7 (~1 час), они закрывают тестовые gap'ы которые ревьюер с хорошим dbt-фоном заметит сразу.
