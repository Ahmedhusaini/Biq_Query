with source as (

    select * from {{ source('product', 'events') }}

)

select
    event_id,
    cast(user_id as {{ dbt.type_bigint() }})   as user_id,   -- = HubSpot contact_id
    event_name,
    cast(event_timestamp as timestamp)         as event_at,
    cast(event_timestamp as date)              as event_date,
    cast(loaded_at as timestamp)               as loaded_at
from source
