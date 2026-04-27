
with mart_side as (
    select sum(fct.n_purchases) as total_n_purchases
    from {{ ref('fct_user_daily') }} fct
    where fct.day_number between 0 and {{ var('max_day_number') }}
),

stg_side as (
    select count(*) as total_n_purchases
    from {{ ref('stg_events') }} s
    join {{ ref('dim_users') }} u using (user_pseudo_id)
    where s.event_name = 'in_app_purchase'
      and (s.event_date_utc - u.cohort_date) between 0 and {{ var('max_day_number') }}
)

select m.total_n_purchases as mart_count, g.total_n_purchases as stg_count
from mart_side m
cross join stg_side g
where coalesce(m.total_n_purchases, 0) != coalesce(g.total_n_purchases, 0)
