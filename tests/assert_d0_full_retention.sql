-- See `tests/_tests.yml` for full docs.

select
    cohort_date,
    cohort_size,
    retained_users,
    retention_pct
from {{ ref('mart_retention_overall') }}
where day_number = 0
  and (
        retained_users != cohort_size
     or retention_pct != 1.0
  )
