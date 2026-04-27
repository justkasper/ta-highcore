select
    user_pseudo_id,
    event_date_utc as activity_date,
    count(*) as events,
    (sum(coalesce(engagement_time_msec, 0)) / 1000.0)::numeric(18, 4) as engagement_sec,
    count(*) filter (where event_name = 'session_start') as n_sessions_proxy
from {{ ref('stg_events') }}
group by 1, 2
