{#-
    User × activity_date with purchase — one row per (user_pseudo_id,
    event_date_utc), only days with at least one `in_app_purchase`. Sparse:
    27 events / 24 distinct users / $24.89 across the whole sample.

    The filter is `event_name = 'in_app_purchase'` (not `event_value_in_usd > 0`).
    Today they match exactly (27/27) but `docs/assumptions.md` #10 picks
    `event_name` as the contract. A guard against "a new monetized event"
    appearing in the source lives in the staging `_models.yml` via
    `expression_is_true`.

    `event_value_in_usd` (DOUBLE) is cast to `numeric(18,4)` before aggregation
    so end-to-end revenue reconciliation matches to the cent.
-#}

select
    user_pseudo_id,
    event_date_utc                                              as activity_date,
    sum(event_value_in_usd::numeric(18, 4))                     as gross_revenue,
    count(*)                                                    as n_purchases
from {{ ref('stg_events') }}
where event_name = 'in_app_purchase'
group by 1, 2
