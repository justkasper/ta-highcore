select
    user_pseudo_id,
    event_date_utc as activity_date,
    sum(event_value_in_usd)::numeric(18, 4) as gross_revenue,
    count(*) as n_purchases
from {{ ref('stg_events') }}
where event_name = 'in_app_purchase'
group by 1, 2
