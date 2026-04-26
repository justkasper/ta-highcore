-- Cumulative revenue must be monotonically non-decreasing as day_number
-- grows within each (cohort_date, install_platform) partition. Same shape
-- as assert_cum_revenue_monotonic.sql, applied to the platform slice.

with ordered as (
    select
        cohort_date,
        install_platform,
        day_number,
        cum_revenue,
        lag(cum_revenue) over (
            partition by cohort_date, install_platform
            order by day_number
        ) as prev_cum_revenue
    from {{ ref('mart_revenue_by_platform') }}
)

select
    cohort_date,
    install_platform,
    day_number,
    cum_revenue,
    prev_cum_revenue
from ordered
where prev_cum_revenue is not null
  and cum_revenue < prev_cum_revenue
