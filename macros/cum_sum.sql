{#-
    Cumulative running sum over (partition_by) ordered by day_number, framed
    `rows between unbounded preceding and current row`. The frame is explicit
    so the compiled SQL is portable to BQ unchanged (BQ defaults to `range
    between unbounded preceding and current row` for `order by`, which can
    bucket ties; rows-frame removes that ambiguity).

    Args:
      col           : column to accumulate (e.g. 'gross_revenue')
      partition_by  : raw SQL fragment for partition columns
                      (e.g. 'cohort_date' or 'cohort_date, install_platform')
-#}
{% macro cum_sum(col, partition_by) -%}
sum({{ col }}) over (
    partition by {{ partition_by }}
    order by day_number
    rows between unbounded preceding and current row
)
{%- endmacro %}
