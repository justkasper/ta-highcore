-- End-to-end paying-users reconciliation:
--   distinct payers attributed in mart_revenue_overall (any cohort, any
--   day_number 0..30) must equal distinct users with at least one
--   in_app_purchase event in stg_events that fell inside their D0..D30
--   cohort window.
--
-- Catches drift between the source revenue stream and the cohort-attributed
-- count in the dashboard. Complements assert_revenue_reconciliation.sql
-- (which checks dollars).

with mart_payers as (
    select count(distinct dim.user_pseudo_id) as payer_count
    from {{ ref('fct_user_daily') }} fct
    join {{ ref('dim_users') }} dim using (user_pseudo_id)
    where fct.day_number between 0 and 30
      and fct.paying_flag
),

stg_payers as (
    select count(distinct s.user_pseudo_id) as payer_count
    from {{ ref('stg_events') }} s
    join {{ ref('dim_users') }} dim using (user_pseudo_id)
    where s.event_name = 'in_app_purchase'
      and s.event_value_in_usd > 0
      and (s.event_date_utc - dim.cohort_date) between 0 and 30
)

select m.payer_count as mart_payers, g.payer_count as stg_payers
from mart_payers m
cross join stg_payers g
where m.payer_count != g.payer_count
