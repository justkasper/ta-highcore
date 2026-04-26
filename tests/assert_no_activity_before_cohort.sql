-- A user cannot be active before their own cohort_date by definition
-- (cohort_date = first observed event date). Any row that violates that
-- invariant is a join bug.

select
    user_pseudo_id,
    cohort_date,
    activity_date
from {{ ref('fct_user_daily') }}
where activity_date < cohort_date
