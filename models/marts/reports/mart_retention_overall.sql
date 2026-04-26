{#-
    Cohort retention, overall (no slice).
    Grain: (cohort_date × day_number).

    Template over the sparse `fct_user_daily`:
    1) `cohorts` — cohort size per cohort_date, computed from dim_users.
    2) `grid` — cohorts × day_numbers densification. Guarantees a row in the
       mart for every (cohort_date, day_number) pair, even if no one reached
       that cell (retained_users = 0, retention_pct = 0).
    3) `retained` — count(distinct user_pseudo_id) per (cohort_date, day_number)
       over the sparse fact.

    On D0, retained == cohort_size by construction (the user is active on
    their own cohort day). That invariant is asserted by the singular test
    `tests/assert_d0_full_retention.sql`.
-#}

with cohorts as (
    select
        cohort_date,
        count(*) as cohort_size
    from {{ ref('dim_users') }}
    group by 1
),

grid as (
    select
        c.cohort_date,
        c.cohort_size,
        d.day_number
    from cohorts c
    cross join {{ ref('day_numbers') }} d
),

retained as (
    select
        cohort_date,
        day_number,
        count(distinct user_pseudo_id) as retained_users
    from {{ ref('fct_user_daily') }}
    where day_number between 0 and 30
    group by 1, 2
)

select
    g.cohort_date,
    g.day_number,
    g.cohort_size,
    coalesce(r.retained_users, 0)                                              as retained_users,
    coalesce(r.retained_users, 0)::numeric(18, 6) / g.cohort_size              as retention_pct
from grid g
left join retained r
    on r.cohort_date = g.cohort_date
   and r.day_number  = g.day_number
