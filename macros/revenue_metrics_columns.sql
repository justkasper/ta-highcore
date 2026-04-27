{#- See `macros/_macros.yml` for full docs. -#}
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
