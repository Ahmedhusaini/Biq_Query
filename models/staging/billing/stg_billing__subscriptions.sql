with source as (

    select * from {{ source('billing', 'subscriptions') }}

)

select
    subscription_id,
    cast(contact_id as {{ dbt.type_bigint() }})    as contact_id,
    plan,
    cast(mrr_eur as {{ dbt.type_numeric() }})      as mrr_eur,
    cast(started_at as timestamp)                  as started_at,
    cast(cancelled_at as timestamp)                as cancelled_at,   -- null = still active
    cancelled_at is not null                       as is_cancelled
from source
