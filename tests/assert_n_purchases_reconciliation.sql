-- End-to-end n_purchases reconciliation:
--   sum(n_purchases) in fct_user_daily within each user's D0..D30 window
-- must equal the count of `in_app_purchase` events in stg_events that fell
-- inside the same cohort window.
--
-- Complements assert_revenue_reconciliation.sql (dollars) and
-- assert_paying_users_reconciliation.sql (distinct payers). n_purchases
-- counts EVERY in_app_purchase event including the 3 with NULL
-- `event_value_in_usd` — that's a documented semantic on `fct_user_daily`,
-- and forgetting it during a refactor (e.g. switching the count to
-- `count(*) filter (where gross_revenue > 0)`) would silently lose those
-- 3 events. This singular pins it.

with mart_side as (
    select sum(fct.n_purchases) as total_n_purchases
    from {{ ref('fct_user_daily') }} fct
    where fct.day_number between 0 and {{ var('max_day_number') }}
),

stg_side as (
    select count(*) as total_n_purchases
    from {{ ref('stg_events') }} s
    join {{ ref('dim_users') }} u using (user_pseudo_id)
    where s.event_name = 'in_app_purchase'
      and (s.event_date_utc - u.cohort_date) between 0 and {{ var('max_day_number') }}
)

select m.total_n_purchases as mart_count, g.total_n_purchases as stg_count
from mart_side m
cross join stg_side g
where coalesce(m.total_n_purchases, 0) != coalesce(g.total_n_purchases, 0)
