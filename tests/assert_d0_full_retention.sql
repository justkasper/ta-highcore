-- On day_number = 0, every cohort member is active by construction
-- (cohort_date = first observed event date). So retained_users must equal
-- cohort_size and retention_pct must equal 1.0 in every D0 row.
-- Any deviation flags a join/aggregation bug in the retention mart.

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
