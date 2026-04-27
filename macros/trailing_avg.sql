{% macro trailing_avg(col, partition_by, days=28) -%}
avg({{ col }}) over (
    partition by {{ partition_by }}
    order by cohort_date
    rows between {{ days }} preceding and 1 preceding
)
{%- endmacro %}
