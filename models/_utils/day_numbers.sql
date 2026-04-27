select cast(generated_number - 1 as integer) as day_number
from (
    {{ dbt_utils.generate_series(upper_bound=var('max_day_number') + 1) }}
)
