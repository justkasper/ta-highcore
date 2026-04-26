with activity as (
    select * from {{ ref('int_user_daily_activity') }}
),

revenue as (
    select * from {{ ref('int_user_daily_revenue') }}
),

users as (
    select user_pseudo_id, cohort_date from {{ ref('dim_users') }}
)

select
    a.user_pseudo_id,
    u.cohort_date,
    a.activity_date,
    (a.activity_date - u.cohort_date) as day_number,
    a.events,
    a.engagement_sec,
    a.n_sessions_proxy,
    coalesce(r.gross_revenue, 0)::numeric(18, 4) as gross_revenue,
    coalesce(r.n_purchases, 0) as n_purchases,
    (coalesce(r.gross_revenue, 0) > 0) as paying_flag
from activity a
join users u
    on u.user_pseudo_id = a.user_pseudo_id
left join revenue r
    on r.user_pseudo_id = a.user_pseudo_id
   and r.activity_date = a.activity_date
