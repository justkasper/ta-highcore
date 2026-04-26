-- Cumulative revenue must be monotonically non-decreasing within each cohort
-- as day_number grows. Any (cohort_date, day_number) row whose cum_revenue is
-- strictly less than the previous day's cum_revenue is a window-function
-- ordering bug.

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
