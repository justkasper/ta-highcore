
with mart_total as (
    select sum(cohort_size) as users_in_mart
    from {{ ref('mart_retention_overall') }}
    where day_number = 0
),
dim_total as (
    select count(*) as users_in_dim
    from {{ ref('dim_users') }}
)

select
    m.users_in_mart,
    d.users_in_dim
from mart_total m
cross join dim_total d
where m.users_in_mart != d.users_in_dim
