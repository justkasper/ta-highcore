with stg as (
    select * from {{ ref('stg_events') }}
),

first_event as (
    select
        user_pseudo_id,
        min(event_date_utc) as cohort_date,
        min(event_ts_utc) as first_event_ts
    from stg
    group by 1
),

attrs as (
    select
        s.user_pseudo_id,
        s.platform as install_platform,
        s.country as install_country,
        s.traffic_medium as install_traffic_medium,
        s.app_id as install_app_id,
        s.event_name as first_event_name,
        row_number() over (
            partition by s.user_pseudo_id
            order by
                s.event_ts_utc,
                s.event_name,
                s.event_bundle_sequence_id nulls last,
                s.event_server_timestamp_offset nulls last
        ) as rn
    from stg s
    join first_event f
        on f.user_pseudo_id = s.user_pseudo_id
       and f.first_event_ts = s.event_ts_utc
),

reinstall_flag as (
    select
        user_pseudo_id,
        coalesce(bool_or(previous_first_open_count > 0), false) as is_reinstall
    from stg
    group by 1
),

events_total as (
    select
        user_pseudo_id,
        count(*) as events_total
    from stg
    group by 1
)

select
    f.user_pseudo_id,
    f.cohort_date,
    a.install_platform,
    a.install_country,
    a.install_traffic_medium,
    a.install_app_id,
    a.first_event_name,
    coalesce(r.is_reinstall, false) as is_reinstall,
    e.events_total
from first_event f
left join attrs a
    on a.user_pseudo_id = f.user_pseudo_id and a.rn = 1
left join reinstall_flag r
    on r.user_pseudo_id = f.user_pseudo_id
left join events_total e
    on e.user_pseudo_id = f.user_pseudo_id
