{#-
    Retention with install_platform slice. Same shape as
    `mart_retention_overall` plus a join to `dim_users` for `install_platform`.

    The dashboard can filter by `install_platform` or compare iOS vs Android
    side by side — no COUNT DISTINCT, no JOIN at the BI layer.
-#}

with users as (
    select user_pseudo_id, cohort_date, install_platform from {{ ref('dim_users') }}
),

cohorts as (
    select
        cohort_date,
        install_platform,
        count(*) as cohort_size
    from users
    group by 1, 2
),

grid as (
    select
        c.cohort_date,
        c.install_platform,
        c.cohort_size,
        d.day_number
    from cohorts c
    cross join {{ ref('day_numbers') }} d
),

fct as (
    select
        f.cohort_date,
        f.day_number,
        u.install_platform,
        f.user_pseudo_id
    from {{ ref('fct_user_daily') }} f
    join users u using (user_pseudo_id)
    where f.day_number between 0 and {{ var('max_day_number') }}
),

retained as (
    select
        cohort_date,
        install_platform,
        day_number,
        count(distinct user_pseudo_id) as retained_users
    from fct
    group by 1, 2, 3
),

joined as (
    select
        g.cohort_date,
        g.install_platform,
        g.day_number,
        g.cohort_size,
        coalesce(r.retained_users, 0) as retained_users,
        coalesce(r.retained_users, 0)::numeric(18, 6) / g.cohort_size as retention_pct
    from grid g
    left join retained r
        on r.cohort_date = g.cohort_date
       and r.install_platform = g.install_platform
       and r.day_number = g.day_number
)

select
    cohort_date,
    install_platform,
    day_number,
    cohort_size,
    retained_users,
    retention_pct,
    {{ trailing_avg('retention_pct', 'day_number, install_platform') }}::numeric(18, 4) as retention_pct_trailing_4w_avg
from joined
