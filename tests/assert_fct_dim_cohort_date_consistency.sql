-- Denormalized cohort_date in fct_user_daily must match dim_users.cohort_date
-- for the same user. Generic tests on fct.cohort_date only see the fact
-- table's own column; if the join in fct_user_daily.sql ever pulls a wrong
-- cohort_date, none of the existing tests catch it. This singular closes
-- that gap.

select
    fct.user_pseudo_id,
    fct.cohort_date as fct_cohort_date,
    dim.cohort_date as dim_cohort_date
from {{ ref('fct_user_daily') }} fct
join {{ ref('dim_users') }} dim using (user_pseudo_id)
where fct.cohort_date != dim.cohort_date
