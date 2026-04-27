{% docs raw_events__eda %}

## Data exploration — `raw.events`

Source-shape findings for `raw.events`: per-column inventory, identifier model, anomalies, monetization signal, and the staging / modeling decisions they drove.

Numbers measured against the local DuckDB warehouse (`data/warehouse.duckdb`) populated by `scripts/prepare_data.py`.

---

### TL;DR

- **5.7 M events / 15,175 users / 114 days** (2018-06-12 → 2018-10-03), Firebase mobile analytics export from a F2P puzzle game (Flood-It!) shipped as **two app builds** (`com.labpixies.flood` on Android, `com.google.flood2` on iOS).
- **This is a sampled dataset, not a full event stream.** Every `event_date` contains *exactly* 50,000 rows (114 × 50,000 = 5,700,000). Cohort sizes and retention are biased low and must be read as relative.
- The "obvious" identity fields lie:
  - `user_id` is **always NULL** (don't use).
  - `ga_session_id` is **never set** (sessions can't be reconstructed from it).
  - `user_first_touch_timestamp` disagrees with the user's first observed event for **97 %** of users.
  - `first_open` is present for only **28 %** of users.
- Monetization signal is **very thin**: 24 paying users / 27 events / $24.89 total. Useful for shape, not for absolute figures.
- Cohort key is `user_pseudo_id`; `cohort_date` is derived from the *first observed `event_date`* per user.

---

### Source and grain

- **Row count**: 5,700,000
- **Distinct `user_pseudo_id`**: 15,175
- **Distinct `user_id`**: 0 (always NULL)
- **Date span**: 2018-06-12 → 2018-10-03 (`event_date`); UTC `event_timestamp` runs 2018-06-12 07:00:10 → 2018-10-04 07:01:23
- **Grain**: one row per emitted Firebase event. There is no natural single-column primary key. The closest near-unique tuple is `(user_pseudo_id, event_timestamp, event_name)` — 207 duplicates exist (≈ 0.004 %).
- **Sampling**: every `event_date` has **exactly 50,000 rows** (114 days × 50,000 = 5,700,000). This is the Firebase public BigQuery sample (`firebase-public-project.analytics_153293282`), not a complete event stream. Cohort sizes and retention will be biased low and must be read as relative, not absolute.

### Volume and shape

| Metric | Value |
|---|---|
| Events | 5,700,000 |
| Distinct `user_pseudo_id` | 15,175 |
| `event_date` span | 2018-06-12 → 2018-10-03 (114 days) |
| `event_timestamp` span (UTC) | 2018-06-12 07:00:10 → 2018-10-04 07:01:23 |
| Platforms | ANDROID 3.03 M / 7,410 users · IOS 2.67 M / 7,765 users |
| Events per user (p50 / p90 / p99 / max) | 52 / 521 / 5,541 / 102,503 |
| Active days per user (most common) | 1 day (7,856 users / 52 %) |

The hard 50,000-rows-per-day cap is the most important property of this dataset to internalize before drawing any conclusions.

### Column inventory

| Column | Type | Coverage | Notes |
|---|---|---|---|
| `event_date` | VARCHAR | 100 % | `YYYYMMDD` string in the property's local TZ. Cast with `strptime(event_date, '%Y%m%d')::date`. Disagrees with `event_timestamp::date` for 1,935,518 rows (34 %) — TZ skew. |
| `event_timestamp` | BIGINT | 100 % | Microseconds since epoch, UTC. Use `make_timestamp(event_timestamp)` or `to_timestamp(event_timestamp / 1e6)`. |
| `event_name` | VARCHAR | 100 % | 37 distinct values. Top: `screen_view` (2.25 M), `user_engagement` (1.36 M), `level_start_quickplay` (523 k). |
| `event_params` | LIST<STRUCT<key, value{string\|int\|double\|float}>> | 100 % | Array of K/V pairs. The right `*_value` field varies per key — see the keys table below. |
| `event_previous_timestamp` | BIGINT | 97 % (170,056 nulls) | 2,994 rows have `prev >= current` — minor anomaly. Not used downstream. |
| `event_value_in_usd` | DOUBLE | 0.0004 % positive | Canonical USD-converted revenue. Set on **27 events / 24 users**, all `in_app_purchase`. Sum = $24.89. |
| `event_bundle_sequence_id` | BIGINT | 100 % | Firebase batching id; not needed for modeling. |
| `event_server_timestamp_offset` | BIGINT | 100 % | Time skew between client and server, microseconds. Not used. |
| `user_id` | VARCHAR | **0 %** | Universally NULL. Drop in staging. |
| `user_pseudo_id` | VARCHAR | 100 % | Cohort/identity key. 0 NULLs / 0 empties. |
| `user_properties` | LIST<STRUCT<key, value{string\|int\|double\|float\|set_timestamp_micros}>> | 100 % | 25 distinct keys (full breakdown below). Notable: `first_open_time` (always set), `_ltv_*` per-currency LTVs, A/B-test flags `firebase_exp_*`. |
| `user_first_touch_timestamp` | BIGINT | 100 % | Reported install/first-touch in microseconds. Disagrees with the user's first observed event for 14,701 / 15,175 users (97 %) — see Identifier model below. |
| `user_ltv` | STRUCT(revenue, currency) | revenue > 0 for 146 users; currency always `USD` | Cumulative LTV at event time. Larger denominator than `event_value_in_usd > 0` (146 vs 24) because LTV is sticky and follows the user across events. |
| `device` | STRUCT | 100 % | Useful: `device.category` (`mobile` / `tablet`), `device.operating_system` (`ANDROID`, `IOS`, `NaN`), `device.language`, `device.mobile_brand_name`. |
| `geo` | STRUCT | 100 % | Useful: `geo.country` (US dominates: 8,168 / 15,175 users), `geo.continent`, `geo.city`. |
| `app_info` | STRUCT | 100 % | Two app builds: `com.labpixies.flood` (Android) and `com.google.flood2` (iOS). Same product, different bundle IDs. |
| `traffic_source` | STRUCT(name, medium, source) | 100 % | 75 % `(direct)/(none)`, 24 % organic via `google-play`, paid campaigns are < 1 %. |
| `stream_id` | VARCHAR | 100 % | Two values: `1051193346` ↔ Android, `1051193347` ↔ iOS. Redundant with `platform`; drop. |
| `platform` | VARCHAR | 100 % | `ANDROID` (3.03 M rows / 7,410 users), `IOS` (2.67 M / 7,765 users). |
| `event_dimensions` | STRUCT | 100 % NULL | Empty in this dataset. Drop. |

### Event vocabulary

37 distinct `event_name` values. Top by volume:

| event_name | events | distinct users |
|---|---:|---:|
| `screen_view` | 2,247,623 | 14,077 |
| `user_engagement` | 1,358,958 | 13,588 |
| `level_start_quickplay` | 523,430 | 10,166 |
| `level_end_quickplay` | 349,729 | 8,168 |
| `post_score` | 242,051 | 8,580 |
| `level_complete_quickplay` | 191,088 | 5,676 |
| `level_fail_quickplay` | 137,035 | 6,343 |
| `select_content` | 105,139 | 11,111 |
| `session_start` | 74,353 | 12,261 |
| `first_open` | 4,322 | 4,319 |
| `in_app_purchase` | 27 | 24 |

Useful for the product brief:

- `first_open` and `session_start` are anchor candidates but partial — see Identifier model below.
- `user_engagement` carries `engagement_time_msec` and is the right field for "active time per user-day".
- `in_app_purchase` is the only event that ever carries `event_value_in_usd > 0`.

### `event_params` keys

Drives the staging extracts: pick the right `*_value` field per key.

| Key | Appearances | Value type | Used downstream |
|---|---:|---|---|
| `firebase_event_origin` | 5,700,000 | string | no (always present, low value) |
| `firebase_screen_class` | 5,569,876 | string | yes — already extracted in `stg_events.sql` |
| `firebase_screen_id` | 5,569,876 | int / double | optional |
| `firebase_previous_class` / `_id` | 2,162,863 | string / int | navigation funnel only |
| `engagement_time_msec` | 1,358,951 | int | yes — only set on `user_engagement`; sum to get user-day engagement |
| `board` | 1,354,028 | string | gameplay context; out of scope for retention |
| `level` | 510,530 | int (10 %) / double (90 %) | mixed type — coalesce |
| `level_name` | 462,309 | string | gameplay |
| `value` | 284,374 | int / double | gameplay (level outcome value) |
| `score` | 242,051 | int / double | gameplay |
| `content_type` / `item_id` | 105,139 / 105,139 | string | UI selection events |
| `previous_first_open_count` | 4,317 | int | re-install detector (`> 0` ⇒ at least one prior install) |

`engagement_time_msec` is well-behaved: 0 negatives, p50 = 3.6 s, p99 = 214 s, max 87 min.

### `user_properties` keys

25 distinct keys. Same struct shape as `event_params` (`{key, value{string|int|double|float|set_timestamp_micros}}`); every key also carries `set_timestamp_micros` (the time the property was last set on the user).

| Key | Appearances | Value type | Used downstream |
|---|---:|---|---|
| `first_open_time` | 5,699,844 | int (microseconds since epoch) | no — `user_first_touch_timestamp` carries the same value at the column level; both lie for 97 % of users |
| `ad_frequency` | 5,160,472 | string (5 distinct values) | no — ad-config flag, out of scope |
| `initial_extra_steps` | 4,895,051 | string (4 distinct) | no — game config |
| `num_levels_available` | 3,035,169 | string (1 distinct) | no — degenerate, single value across the dataset |
| `firebase_exp_3` | 2,596,238 | string (4 distinct) | optional — A/B variant; expose as slice if A/B analysis is needed |
| `plays_quickplay` | 2,444,654 | string (1 distinct) | no — single-value flag, equivalent to "has emitted any quickplay event" |
| `plays_progressive` | 1,496,168 | string (1 distinct) | no — single-value flag |
| `firebase_exp_1` | 1,328,492 | string (4 distinct) | optional — A/B variant |
| `firebase_exp_4` | 896,106 | string (3 distinct) | optional — A/B variant |
| `firebase_last_notification` | 352,684 | string (12 distinct) | no — last push-notification id |
| `_ltv_USD` | 65,192 | int | yes (sparse) — per-currency raw LTV; redundant with `user_ltv.revenue` for marts (already USD-converted) |
| `_ltv_JPY` / `_AUD` / `_DKK` / `_GBP` / `_CHF` / `_TWD` / `_AED` / `_PKR` / `_EUR` / `_MXN` / `_SEK` / `_RON` | 18,816 → 1 | int | no — per-currency long tail; prefer `event_value_in_usd` for new revenue and `user_ltv.revenue` for cumulative |
| `firebase_exp_5` / `_7` | 16,555 / 2 | string | no — minor A/B variants |

`first_open_time` covers 99.997 % of events (every event except 156). The `_ltv_*` family is the per-currency raw form of cumulative LTV; we use the column-level `user_ltv.revenue` (always `USD`) and event-level `event_value_in_usd` for monetization rather than parsing these keys.

### Identifier model

`user_pseudo_id` is the only stable identity here. It is **never null or empty**, and **no user spans both platforms** (each pseudo id is single-platform). It is safe to use as the cohort key with no further cleaning.

The other identity fields are unhelpful or actively misleading:

- `user_id` — set by `setUserId`. **0 / 5,700,000 events** carry a non-null value. Drop in staging.
- `ga_session_id` — Google's session identifier. **0 / 5,700,000 events** carry a value. Sessions cannot be reconstructed from this field. If session-level metrics are required, derive from `session_start` event arrivals (74,353 events / 12,261 users) or from activity gaps within `user_engagement`.
- `user_first_touch_timestamp` — present on every event, but disagrees with the user's first observed event for **14,701 / 15,175 users (97 %)**:
  - 10,726 users (71 %) had `uft` *before* the window — they are pre-existing users; their cohort is outside the sample.
  - 3,975 users (26 %) have `uft` *after* the user's first observed event — a data quality artefact; the value gets re-stamped later in the user's lifecycle by some events (`firebase_campaign` is a likely culprit).
- `first_open` event — present for only **4,319 / 15,175 users (28 %)**. Of those 4,319, 161 had `previous_first_open_count > 0` (re-installs). Cannot anchor the cohort universally on this event.

**Cohort anchor**: `cohort_date = min(event_date) per user_pseudo_id`. It is the only definition that covers 100 % of users and is internally consistent with the sample. The trade-off (and assumption to log) is that left-censored users — those whose true install predates 2018-06-12 — will appear in their first sample-window day's cohort and inflate that bucket; that bias is most visible on 2018-06-12 itself.

### Timestamps and date semantics

`event_date` is a `VARCHAR` in `YYYYMMDD` format in the **property's local time zone**; `event_timestamp` is microseconds since epoch in **UTC**. The two disagree on **34 % of rows** (1,935,518). The project standardizes on UTC: staging derives `event_ts_utc = make_timestamp(event_timestamp)` and `event_date_utc = event_ts_utc::date`, and downstream models cohort on `event_date_utc`. The source `event_date` is preserved only for source-reconciliation checks.

`event_previous_timestamp` is null on 3 % of rows and "in the future" (≥ current) on 2,994 rows. Not used downstream.

### Data quality issues

At-a-glance:

| # | Finding | Rows / users | Implication |
|---|---|---|---|
| 1 | Per-day sample cap of exactly 50,000 events | 114 days | All cohort sizes are partial. Frame metrics as relative. |
| 2 | `event_date` ≠ `event_timestamp::date` | 1,935,518 (34 %) | TZ skew — choose UTC-derived date for cohorting. |
| 3 | `user_id` always null | 5.7 M | Drop. |
| 4 | `ga_session_id` never set | 5.7 M | Cannot derive sessions from it. |
| 5 | `user_first_touch_timestamp` ≠ first observed event | 14,701 users (97 %) | Don't use `uft` as cohort anchor; use first observed `event_date`. |
| 6 | `first_open` missing for 72 % of users | 10,856 users | Cannot anchor on `first_open` alone. |
| 7 | Duplicate rows on `(user_pseudo_id, event_timestamp, event_name)` | 207 (0.004 %) | Dedup with `qualify row_number()=1` in staging. |
| 8 | `device.operating_system = 'NaN'` literal | ~337 k events / ~2.4 k users | Treat as unknown OS. |
| 9 | 52 % of users seen on exactly one `event_date` | 7,856 users | High one-day churn / lurker share. |
| 10 | `event_dimensions` 100 % null; `stream_id` 1:1 with `platform` | all rows | Drop both. |
| 11 | Two `app_info.id` values (Android and iOS bundles) | n/a | Same product, two builds. Mostly aligned with `platform`. |
| 12 | `traffic_source` very sparse: 75 % `(direct)/(none)`, 24 % `organic/google-play`, < 1 % paid | n/a | Limits the value of an "install source" slice but worth surfacing the top-3 categories. |
| 13 | `level` param has mixed value types (10 % `int_value`, 90 % `double_value`) | 510 k | Coalesce in extraction. |

Detail on the entries that need more than a one-liner:

1. **Per-day sampling cap (50,000 events / day, exact)** — not a bug, a sampling artefact. Every cohort metric must be qualified as "within sample". The first sample day (2018-06-12) shows 449 "new" users not because that's the install rate, but because everyone present that day is "new" by construction; left-censored users land here.
2. **TZ skew** — `event_date` is property-local; `event_timestamp` is UTC. The project picks UTC as the cohort anchor. The source `event_date` is reserved for direct comparisons against the source.
5. **`uft` 97 % mismatch breakdown** — 71 % of users (`uft` before window) are pre-existing; 26 % (`uft` after first observed event) are a data quality artefact where `uft` is re-stamped later in the user's lifecycle. Don't use `uft` as the cohort anchor.
6. **`first_open` partial coverage**: only 4,319 / 15,175 users emit it. Of those, 161 are re-installs (`previous_first_open_count > 0`). Cannot anchor universally on `first_open`.
7. **Duplicates**: 207 rows share `(user_pseudo_id, event_timestamp, event_name)` — a tiny share but enough to break a `unique` test. Dedup once in staging via `qualify row_number() over (partition by user_pseudo_id, event_timestamp, event_name order by event_bundle_sequence_id) = 1`.

### Monetization

Two related but inconsistent revenue signals:

| Signal | Users | Notes |
|---|---:|---|
| `event_value_in_usd > 0` (event-level) | 24 | All on `in_app_purchase`. Sum $24.89, max $1.99, min $0.92. Canonical for revenue mart. |
| `user_ltv.revenue > 0` | 146 | Cumulative LTV stamped on every event after the first purchase. Currency is always `USD` (already converted). |
| `user_properties._ltv_USD` etc. | 109 (USD), small per-currency tails (`_ltv_JPY`, `_ltv_GBP`, …) | Per-currency raw LTVs; not needed if we use `event_value_in_usd` and `user_ltv.revenue` for the marts. |

The 24 vs 146 gap is consistent: 122 users carry an `_ltv_*` property but never had a purchase event in the sample window — their purchase happened *before* 2018-06-12 and only the LTV memory survives.

For the cohort retention/monetization marts: `event_value_in_usd` is the only signal we can attribute to *new* revenue in the sample window, and the LTV gap is called out as known leakage.

### Relationships

Single-source dataset; no foreign keys to validate. The only "joins" of interest are unnesting the `event_params` and `user_properties` lists into wide columns at the staging layer.

### Staging transformations applied

The decisions below follow directly from the findings above and are now implemented in `stg_events`:

1. Cast `event_date` to `DATE` via `strptime(event_date, '%Y%m%d')::date`.
2. Derive `event_ts_utc = make_timestamp(event_timestamp)` and `event_date_utc = event_ts_utc::date`. Use `event_date_utc` as the cohort-math anchor; keep raw `event_date` only for source-comparison checks.
3. Drop `user_id` (always null), `event_dimensions` (always null), `stream_id` (redundant with `platform`).
4. Extract typed columns from `event_params` for the params actually used: `engagement_time_msec` (int), `firebase_screen_class` (string), and `level` / `level_name` / `score` / `value` only if a gameplay mart is built. For mixed-type keys (e.g. `level`), coalesce `int_value` and `double_value`.
5. Promote struct fields to top-level columns: `geo.country`, `device.category`, `device.operating_system`, `device.language`, `app_info.id`, `app_info.version`, `traffic_source.name`, `traffic_source.medium`, `traffic_source.source`.
6. Per-user roll-up (`stg_users`): `cohort_date` derived from the first observed `event_date_utc` (not `user_first_touch_timestamp`, which lies for 97 % of users). Carries `first_event_name`, install platform, install country, install traffic source.
7. Purchase isolation (`stg_purchases`): filtered on `event_value_in_usd > 0` (the canonical signal — currently 27 events). Sparse monetization signal documented in the mart.
8. Deduplicate on `(user_pseudo_id, event_timestamp, event_name)` (207 rows / 0.004 %) so `unique` tests on that grain pass.

### Modeling decisions

These flow from the findings above and shape the intermediate / mart layer:

1. **Identity**: `user_pseudo_id` only; `user_id` dropped.
2. **Cohort anchor**: first observed `event_date_utc` per `user_pseudo_id`. Documented assumption: left-censored users inflate the first window day's cohort.
3. **Activity definition**: a user is "active on day N" if they emit *any* event on `cohort_date + N`. Day 0 is the cohort day itself. Retention is binary by user-day.
4. **Sessions**: skipped at the metric level, or proxied with `session_start` events. `ga_session_id` not used.
5. **Engagement time**: sum `engagement_time_msec` from `user_engagement` events per user-day.
6. **Revenue**: `event_value_in_usd` from `in_app_purchase` events. Sparsity surfaced in mart docs.
7. **Re-installs**: ignored for now; `previous_first_open_count > 0` flagged in `dim_users` for future exclusion.
8. **Slices exposed**: `platform` (clean 2-way), `geo.country` (top-N + Other), `app_info.id` (Android vs iOS bundles), `traffic_source.medium` (direct / organic / cpc / other). Paid-campaign drilldowns are not exposed — too sparse.
9. **Sample disclaimer**: every dashboard page carries a "this is a 50k-events/day sample" footnote so cohort sizes aren't misread as absolute.

{% enddocs %}
