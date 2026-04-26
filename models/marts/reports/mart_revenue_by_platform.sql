{#-
    Cohort revenue with install_platform slice. Same shape as mart_revenue_overall
    plus platform partition for window functions and group-by.

    With ~$25 of revenue across 24 payers in the whole sample, slice numbers
    are sparse — kept in scope to demonstrate the pattern (see
    docs/architecture.md decision #4).
-#}

with users as (
    select user_pseudo_id, cohort_date, install_platform from {{ ref('dim_users') }}
),

cohorts as (
    select
        cohort_date,
        install_platform,
        count(*) as cohort_size
    from users
    group by 1, 2
),

grid as (
    select
        c.cohort_date,
        c.install_platform,
        c.cohort_size,
        d.day_number
    from cohorts c
    cross join {{ ref('day_numbers') }} d
),

fct as (
    select
        f.cohort_date,
        f.day_number,
        u.install_platform,
        f.user_pseudo_id,
        f.gross_revenue,
        f.paying_flag
    from {{ ref('fct_user_daily') }} f
    join users u using (user_pseudo_id)
    where f.day_number between 0 and 30
),

daily as (
    select
        cohort_date,
        install_platform,
        day_number,
        sum(gross_revenue)::numeric(18, 4)                                as gross_revenue,
        count(distinct case when paying_flag then user_pseudo_id end)     as paying_users
    from fct
    group by 1, 2, 3
),

joined as (
    select
        g.cohort_date,
        g.install_platform,
        g.day_number,
        g.cohort_size,
        coalesce(d.gross_revenue, 0)::numeric(18, 4) as gross_revenue,
        coalesce(d.paying_users, 0)                  as paying_users
    from grid g
    left join daily d
        on d.cohort_date      = g.cohort_date
       and d.install_platform = g.install_platform
       and d.day_number       = g.day_number
)

select
    cohort_date,
    install_platform,
    day_number,
    cohort_size,
    gross_revenue,
    paying_users,
    sum(gross_revenue) over (
        partition by cohort_date, install_platform
        order by day_number
        rows between unbounded preceding and current row
    )::numeric(18, 4)                                                  as cum_revenue,
    sum(paying_users) over (
        partition by cohort_date, install_platform
        order by day_number
        rows between unbounded preceding and current row
    )                                                                  as cum_paying_users,
    (sum(gross_revenue) over (
        partition by cohort_date, install_platform
        order by day_number
        rows between unbounded preceding and current row
    ) / cohort_size)::numeric(18, 6)                                   as cum_arpu,
    case
        when sum(paying_users) over (
                partition by cohort_date, install_platform
                order by day_number
                rows between unbounded preceding and current row
             ) = 0
            then null
        else sum(gross_revenue) over (
                partition by cohort_date, install_platform
                order by day_number
                rows between unbounded preceding and current row
             )::numeric(18, 6)
             / sum(paying_users) over (
                partition by cohort_date, install_platform
                order by day_number
                rows between unbounded preceding and current row
             )
    end                                                                as cum_arppu,
    sum(paying_users) over (
        partition by cohort_date, install_platform
        order by day_number
        rows between unbounded preceding and current row
    )::numeric(18, 6) / cohort_size                                    as paying_share
from joined
