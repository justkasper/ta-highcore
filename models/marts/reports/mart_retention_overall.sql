with cohorts as (
    select
        cohort_date,
        count(*) as cohort_size
    from {{ ref('dim_users') }}
    group by 1
),

grid as (
    select
        c.cohort_date,
        c.cohort_size,
        d.day_number
    from cohorts c
    cross join {{ ref('day_numbers') }} d
),

retained as (
    select
        cohort_date,
        day_number,
        count(distinct user_pseudo_id) as retained_users
    from {{ ref('fct_user_daily') }}
    where day_number between 0 and {{ var('max_day_number') }}
    group by 1, 2
),

joined as (
    select
        g.cohort_date,
        g.day_number,
        g.cohort_size,
        coalesce(r.retained_users, 0) as retained_users,
        coalesce(r.retained_users, 0)::numeric(18, 6) / g.cohort_size as retention_pct
    from grid g
    left join retained r
        on r.cohort_date = g.cohort_date
       and r.day_number  = g.day_number
)

select
    cohort_date,
    day_number,
    cohort_size,
    retained_users,
    retention_pct,
    {{ trailing_avg('retention_pct', 'day_number') }}::numeric(18, 4) as retention_pct_trailing_4w_avg
from joined
