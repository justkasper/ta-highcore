{#-
    Cohort revenue overall (no slice).
    Grain: (cohort_date × day_number).

    Standard F2P 4-pack:
      - paying_users         — distinct payers seen on this exact day_number
      - cum_paying_users     — distinct payers seen up to and including day_number
      - gross_revenue        — revenue earned on this exact day_number
      - cum_revenue          — sum of revenue from D0 through day_number
      - cum_arpu             — cum_revenue / cohort_size
      - cum_arppu            — cum_revenue / cum_paying_users (NULL when no payers yet)
      - paying_share         — cum_paying_users / cohort_size

    Cum_* are computed via SUM(...) OVER (PARTITION BY cohort_date ORDER BY day_number),
    so they are monotonically non-decreasing within each cohort. That invariant is
    asserted in tests/assert_cum_revenue_monotonic.sql.

    Densification template matches mart_retention_overall: cohorts × day_numbers
    grid with LEFT JOIN onto the sparse fact aggregate.
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

daily as (
    select
        cohort_date,
        day_number,
        sum(gross_revenue)::numeric(18, 4)                        as gross_revenue,
        count(distinct case when paying_flag then user_pseudo_id end) as paying_users
    from {{ ref('fct_user_daily') }}
    where day_number between 0 and 30
    group by 1, 2
),

joined as (
    select
        g.cohort_date,
        g.day_number,
        g.cohort_size,
        coalesce(d.gross_revenue, 0)::numeric(18, 4) as gross_revenue,
        coalesce(d.paying_users, 0)                  as paying_users
    from grid g
    left join daily d
        on d.cohort_date = g.cohort_date
       and d.day_number  = g.day_number
)

select
    cohort_date,
    day_number,
    cohort_size,
    gross_revenue,
    paying_users,
    sum(gross_revenue) over (
        partition by cohort_date
        order by day_number
        rows between unbounded preceding and current row
    )::numeric(18, 4)                                              as cum_revenue,
    sum(paying_users) over (
        partition by cohort_date
        order by day_number
        rows between unbounded preceding and current row
    )                                                              as cum_paying_users,
    (sum(gross_revenue) over (
        partition by cohort_date
        order by day_number
        rows between unbounded preceding and current row
    ) / cohort_size)::numeric(18, 6)                               as cum_arpu,
    case
        when sum(paying_users) over (
                partition by cohort_date
                order by day_number
                rows between unbounded preceding and current row
             ) = 0
            then null
        else sum(gross_revenue) over (
                partition by cohort_date
                order by day_number
                rows between unbounded preceding and current row
             )::numeric(18, 6)
             / sum(paying_users) over (
                partition by cohort_date
                order by day_number
                rows between unbounded preceding and current row
             )
    end                                                            as cum_arppu,
    sum(paying_users) over (
        partition by cohort_date
        order by day_number
        rows between unbounded preceding and current row
    )::numeric(18, 6) / cohort_size                                as paying_share
from joined
