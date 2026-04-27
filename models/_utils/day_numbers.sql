select unnest(generate_series(0, {{ var('max_day_number') }})) as day_number
