{#-
    Trailing window average of `col` over preceding cohorts. Used to
    surface "current cohort vs trailing baseline" metrics on the
    dashboard (see `docs/dashboard_sketch.md`) without forcing BI to
    compute the window itself.

    The window EXCLUDES the current row (`rows between N preceding and
    1 preceding`) so the baseline is independent of the cohort being
    compared against it. Returns NULL for the first cohort at each
    partition (no preceding history) — intentional; the dashboard
    renders NULL as "no baseline yet".

    Args:
      col          : column to average — must already exist in the
                     calling SELECT scope (typically a metric like
                     `retention_pct` or `cum_arpu`)
      partition_by : raw SQL fragment for the window partition. Hold
                     `day_number` constant; extend with slice columns
                     where the baseline should be per-slice.
                     Examples:
                       'day_number'                       — overall mart
                       'day_number, install_platform'     — sliced mart
      days         : window length in preceding cohorts (default 28 = 4 weeks)
-#}
{% macro trailing_avg(col, partition_by, days=28) -%}
avg({{ col }}) over (
    partition by {{ partition_by }}
    order by cohort_date
    rows between {{ days }} preceding and 1 preceding
)
{%- endmacro %}
