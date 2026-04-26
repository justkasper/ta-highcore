{#-
    Emits the cumulative revenue-metrics SELECT-list block that
    `mart_revenue_overall` and `mart_revenue_by_platform` share.
    Output columns (in this order):
      cum_revenue, cum_paying_users, cum_arpu, cum_arppu, paying_share

    The macro expects these columns to be available in the calling context:
      gross_revenue, paying_users  — daily counters (after coalesce-to-zero)
      cohort_size                  — denominator at the same grain as
                                     partition_by
      day_number                   — used as the window order

    Trailing comma is intentionally omitted — the macro emits the LAST
    columns of the SELECT-list, so the caller should not append more
    columns after the macro call.

    Args:
      partition_by : raw SQL fragment for the cumulative window's
                     partition columns (must be the same grain that
                     produced cohort_size). Example values:
                       'cohort_date'                       — overall mart
                       'cohort_date, install_platform'     — sliced mart
-#}
{% macro revenue_metrics_columns(partition_by) -%}
    {{ cum_sum('gross_revenue', partition_by) }}::numeric(18, 4) as cum_revenue,
    {{ cum_sum('paying_users', partition_by) }} as cum_paying_users,
    ({{ cum_sum('gross_revenue', partition_by) }} / cohort_size)::numeric(18, 4) as cum_arpu,
    case
        when {{ cum_sum('paying_users', partition_by) }} = 0
            then null
        else (
            {{ cum_sum('gross_revenue', partition_by) }}::numeric(18, 4)
            / {{ cum_sum('paying_users', partition_by) }}
        )::numeric(18, 4)
    end as cum_arppu,
    ({{ cum_sum('paying_users', partition_by) }}::numeric(18, 4) / cohort_size)::numeric(18, 4) as paying_share
{%- endmacro %}
