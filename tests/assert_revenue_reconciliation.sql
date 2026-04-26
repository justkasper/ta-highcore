-- End-to-end revenue reconciliation:
--   total cum_revenue at the LAST seen day_number per cohort, summed across
--   cohorts (= D30 cumulative revenue per cohort)
-- must equal the sum of in_app_purchase event_value_in_usd from stg_events
-- restricted to events that fall inside that user's D0..D30 cohort window.
--
-- Casts are aligned to numeric(18,4) on both sides so float drift cannot
-- introduce false positives.

with mart_side as (
    select sum(cum_revenue)::numeric(18, 4) as total_revenue_d30
    from {{ ref('mart_revenue_overall') }}
    where day_number = 30
),

stg_side as (
    select sum(s.event_value_in_usd::numeric(18, 4))::numeric(18, 4) as total_revenue_in_window
    from {{ ref('stg_events') }} s
    join {{ ref('dim_users') }} u using (user_pseudo_id)
    where s.event_name = 'in_app_purchase'
      and (s.event_date_utc - u.cohort_date) between 0 and {{ var('max_day_number') }}
)

select
    m.total_revenue_d30,
    g.total_revenue_in_window
from mart_side m
cross join stg_side g
where coalesce(m.total_revenue_d30, 0) != coalesce(g.total_revenue_in_window, 0)
