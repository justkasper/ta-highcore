-- D0 full-retention invariant for the platform-sliced mart:
--   For every (cohort_date, install_platform) at day_number = 0,
--   retained_users must equal cohort_size and retention_pct must be 1.0.
--
-- Same invariant as assert_d0_full_retention.sql but on the by_platform
-- variant — guards the platform-partitioned join independently.

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
