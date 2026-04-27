-- See `tests/_tests.yml` for full docs.

select
    r.user_pseudo_id,
    r.activity_date
from {{ ref('int_user_daily_revenue') }} r
left join {{ ref('int_user_daily_activity') }} a
    on  a.user_pseudo_id = r.user_pseudo_id
    and a.activity_date  = r.activity_date
where a.user_pseudo_id is null
