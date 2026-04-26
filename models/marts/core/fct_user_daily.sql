{#-
    ★ Central fact ★ — user × activity_date, sparse.

    A row exists iff the user was active on that day. There is no `is_active`
    column — its role is played by row presence. Inactive days are not
    materialized.

    Atomic F2P grain: any future report (cohort retention, funnels, weekly
    retention, A/B slices) is a GROUP BY over this star with no changes to the
    `core` layer.

    Sparse on purpose:
    - On BigQuery on-demand pricing, a dense fact would carry ~60% rows with
      `is_active = 0` — bytes scanned for nothing on every query.
    - Densification onto the (cohort_date × day_number) grid happens in
      `reports/` via `cross join day_numbers`. The date-spine is tiny and does
      not move bytes_scanned in BQ.
    - Semantically clean: a "fact" is what happened, not what we want to show.

    `cohort_date` is denormalized here from `dim_users` so that reports can
    filter without an extra JOIN.
-#}

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
    (a.activity_date - u.cohort_date)                          as day_number,
    a.events,
    a.engagement_sec,
    a.n_sessions_proxy,
    coalesce(r.gross_revenue, 0)::numeric(18, 4)               as gross_revenue,
    coalesce(r.n_purchases, 0)                                 as n_purchases,
    (coalesce(r.gross_revenue, 0) > 0)                         as paying_flag
from activity a
join users u
    on u.user_pseudo_id = a.user_pseudo_id
left join revenue r
    on r.user_pseudo_id = a.user_pseudo_id
   and r.activity_date = a.activity_date
