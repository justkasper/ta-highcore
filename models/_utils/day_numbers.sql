{#-
    Date-spine for densification of (cohort_date × day_number) in reports/.
    D0..D30 inclusive (31 rows).

    The D30 window is a product decision. Changing the window means editing 
    this single view rather than every report. To extend to D60 or D90, 
    raise the upper bound here.
-#}

select unnest(generate_series(0, 30)) as day_number
