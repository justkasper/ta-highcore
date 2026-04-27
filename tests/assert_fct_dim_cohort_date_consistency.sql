-- See `tests/_tests.yml` for full docs.

select
    fct.user_pseudo_id,
    fct.cohort_date as fct_cohort_date,
    dim.cohort_date as dim_cohort_date
from {{ ref('fct_user_daily') }} fct
join {{ ref('dim_users') }} dim using (user_pseudo_id)
where fct.cohort_date != dim.cohort_date
