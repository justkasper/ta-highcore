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
        f.user_pseudo_id,
        f.gross_revenue,
        f.paying_flag
    from {{ ref('fct_user_daily') }} f
    join users u using (user_pseudo_id)
    where f.day_number between 0 and 30
),

daily as (
    select
        cohort_date,
        install_platform,
        day_number,
        sum(gross_revenue)::numeric(18, 4) as gross_revenue,
        count(distinct case when paying_flag then user_pseudo_id end) as paying_users
    from fct
    group by 1, 2, 3
),

joined as (
    select
        g.cohort_date,
        g.install_platform,
        g.day_number,
        g.cohort_size,
        coalesce(d.gross_revenue, 0)::numeric(18, 4) as gross_revenue,
        coalesce(d.paying_users, 0) as paying_users
    from grid g
    left join daily d
        on d.cohort_date      = g.cohort_date
       and d.install_platform = g.install_platform
       and d.day_number       = g.day_number
)

select
    cohort_date,
    install_platform,
    day_number,
    cohort_size,
    gross_revenue,
    paying_users,
    {{ revenue_metrics_columns('cohort_date, install_platform') }}
from joined
