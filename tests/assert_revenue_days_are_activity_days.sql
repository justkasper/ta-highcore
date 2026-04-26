-- Every (user_pseudo_id, activity_date) pair in `int_user_daily_revenue`
-- must also exist in `int_user_daily_activity`. The invariant holds today
-- because `int_user_daily_activity` groups every event by `event_date_utc`
-- and `in_app_purchase` is itself an event — but it's an implicit
-- consequence of the staging filter, not an enforced contract. If
-- `int_user_daily_activity` ever gains a stricter event-name filter
-- (e.g. excluding system events), purchase rows could fall through
-- `fct_user_daily`'s `from activity LEFT JOIN revenue` join and silently
-- lose revenue.

select
    r.user_pseudo_id,
    r.activity_date
from {{ ref('int_user_daily_revenue') }} r
left join {{ ref('int_user_daily_activity') }} a
    on  a.user_pseudo_id = r.user_pseudo_id
    and a.activity_date  = r.activity_date
where a.user_pseudo_id is null
