-- day_number must always equal (activity_date - cohort_date). Any drift
-- between the column and its definition is a logic bug we want to catch
-- before reports compute on it.

select
    user_pseudo_id,
    cohort_date,
    activity_date,
    day_number,
    (activity_date - cohort_date) as expected_day_number
from {{ ref('fct_user_daily') }}
where day_number is distinct from (activity_date - cohort_date)
