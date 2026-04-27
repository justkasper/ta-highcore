
select
    cohort_date,
    install_platform,
    cohort_size,
    retained_users,
    retention_pct
from {{ ref('mart_retention_by_platform') }}
where day_number = 0
  and (
        retained_users != cohort_size
     or retention_pct != 1.0
  )
