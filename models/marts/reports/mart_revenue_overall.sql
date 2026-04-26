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

daily as (
    select
        cohort_date,
        day_number,
        sum(gross_revenue)::numeric(18, 4) as gross_revenue,
        count(distinct case when paying_flag then user_pseudo_id end) as paying_users
    from {{ ref('fct_user_daily') }}
    where day_number between 0 and {{ var('max_day_number') }}
    group by 1, 2
),

joined as (
    select
        g.cohort_date,
        g.day_number,
        g.cohort_size,
        coalesce(d.gross_revenue, 0)::numeric(18, 4) as gross_revenue,
        coalesce(d.paying_users, 0) as paying_users
    from grid g
    left join daily d
        on d.cohort_date = g.cohort_date
       and d.day_number  = g.day_number
),

metrics as (
    select
        cohort_date,
        day_number,
        cohort_size,
        gross_revenue,
        paying_users,
        {{ revenue_metrics_columns('cohort_date') }}
    from joined
)

select
    metrics.*,
    {{ trailing_avg('cum_arpu', 'day_number') }}::numeric(18, 4) as cum_arpu_trailing_4w_avg
from metrics
