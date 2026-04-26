{#-
    User × activity_date, sparse — one row per (user_pseudo_id, event_date_utc),
    only days where the user emitted at least one event. Missing row = "nothing
    happened that day".

    `engagement_sec` = sum(engagement_time_msec) / 1000. Zero on days with no
    engagement-bearing events (NULL → coalesce → 0). The outlier flag based on
    per-user event volume is set on user grain in `dim_users`, not here.

    `n_sessions_proxy` — count of `session_start` events per day. It's a proxy
    because `ga_session_id` is 100% NULL in the source, so we can't reconstruct
    sessions exactly. ~19% of users never emit `session_start`; for them
    `n_sessions_proxy` is 0 even on active days.
-#}

select
    user_pseudo_id,
    event_date_utc                                              as activity_date,
    count(*)                                                    as events,
    sum(coalesce(engagement_time_msec, 0)) / 1000.0             as engagement_sec,
    count(*) filter (where event_name = 'session_start')        as n_sessions_proxy
from {{ ref('stg_events') }}
group by 1, 2
