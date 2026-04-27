
with ordered as (
    select
        cohort_date,
        day_number,
        cum_revenue,
        lag(cum_revenue) over (
            partition by cohort_date
            order by day_number
        ) as prev_cum_revenue
    from {{ ref('mart_revenue_overall') }}
)

select
    cohort_date,
    day_number,
    cum_revenue,
    prev_cum_revenue
from ordered
where prev_cum_revenue is not null
  and cum_revenue < prev_cum_revenue
