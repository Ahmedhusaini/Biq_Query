{{ config(materialized = 'ephemeral') }}

-- Calendar of months from reporting_start_date up to and including the current month.
-- Ephemeral: compiled into the models that use it as a CTE, never built as a table.

with spine as (

    {{ dbt.date_spine(
        datepart = "month",
        start_date = "cast('" ~ var('reporting_start_date') ~ "' as date)",
        end_date = dbt.dateadd('month', 1, dbt.date_trunc('month', dbt.current_timestamp()))
    ) }}

)

select
    cast(date_month as date)                                    as month_start,
    cast({{ dbt.dateadd('month', 1, 'date_month') }} as date)   as next_month_start
from spine
