{#-
    Date-spine for densification of (cohort_date × day_number) in reports/.
    D0..D{var('max_day_number')} inclusive (default 31 rows).

    The D-window is a product decision. To extend to D60/D90, raise
    `vars.max_day_number` in `dbt_project.yml` — single source of truth
    that drives both this view AND the `where day_number between 0 and
    var(...)` filters in every report mart.
-#}

select unnest(generate_series(0, {{ var('max_day_number') }})) as day_number
