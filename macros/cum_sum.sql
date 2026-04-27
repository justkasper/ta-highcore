{#- See `macros/_macros.yml` for full docs. -#}
{% macro cum_sum(col, partition_by) -%}
sum({{ col }}) over (
    partition by {{ partition_by }}
    order by day_number
    rows between unbounded preceding and current row
)
{%- endmacro %}
