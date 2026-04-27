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
    b.install_traffic_medium,
    b.install_app_id,
    b.first_event_name,
    b.is_reinstall,
    (b.events_total > p.events_p99) as is_outlier_events
from base b
cross join p99 p
