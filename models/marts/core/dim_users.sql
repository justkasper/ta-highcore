{#-
    User dimension at user grain. One row per `user_pseudo_id`.

    Clean star schema: every slowly-changing user attribute (cohort, install,
    flags) lives here; `fct_user_daily` joins back via FK. `cohort_size`
    invariants in tests use `dim_users` as the independent source of truth.

    `is_outlier_events` uses a dynamic p99 over `events_total`. Hardcoding the
    threshold (≈ 5541 per EDA) would be fragile to refresh; flagging a fraction
    of rows is the right ergonomics for a "heavy users may dominate metrics"
    signal.
-#}

with base as (
    select * from {{ ref('int_user_install') }}
),

p99 as (
    select percentile_cont(0.99) within group (order by events_total) as events_p99
    from base
)

select
    b.user_pseudo_id,
    b.cohort_date,
    b.install_platform,
    b.install_country,
    b.install_country_top5,
    b.install_traffic_medium,
    b.install_app_id,
    b.first_event_name,
    b.is_reinstall,
    (b.events_total > p.events_p99) as is_outlier_events
from base b
cross join p99 p
