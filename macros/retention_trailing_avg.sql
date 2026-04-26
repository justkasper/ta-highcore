{#-
    Trailing window average of `retention_pct` over preceding cohorts at
    the same day_number. Used by both retention marts to expose the
    "current cohort vs trailing baseline" line on the dashboard
    (see `docs/dashboard_sketch.md` Block 3).

    The window EXCLUDES the current row (`rows between N preceding and
    1 preceding`) so the baseline is independent of the cohort being
    compared against it. Returns NULL for the first `days` cohorts
    where there is no preceding history — this is intentional;
    the dashboard renders NULL as "no baseline yet".

    Args:
      partition_by : raw SQL fragment for the window partition. Must
                     hold day_number constant; extend with slice
                     columns where the baseline should be per-slice.
                     Examples:
                       'day_number'                       — overall mart
                       'day_number, install_platform'     — sliced mart
      days         : window length in preceding cohorts (default 28 = 4 weeks)
-#}
{% macro retention_trailing_avg(partition_by, days=28) -%}
avg(retention_pct) over (
    partition by {{ partition_by }}
    order by cohort_date
    rows between {{ days }} preceding and 1 preceding
)
{%- endmacro %}
