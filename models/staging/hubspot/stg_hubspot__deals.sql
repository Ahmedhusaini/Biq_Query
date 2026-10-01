with source as (

    select * from {{ source('hubspot', 'deals') }}

),

renamed as (

    select
        cast(deal_id as {{ dbt.type_bigint() }})                 as deal_id,
        cast(associated_contact_id as {{ dbt.type_bigint() }})   as contact_id,
        dealstage                                                as deal_stage,
        case
            when dealstage = 'closedwon'  then 'won'
            when dealstage = 'closedlost' then 'lost'
            else 'open'
        end                                                      as deal_status,
        cast(amount as {{ dbt.type_numeric() }})                 as amount_eur,
        plan,
        cast(createdate as timestamp)                            as created_at,
        cast(closedate as timestamp)                             as closed_at,  -- null while open
        cast(lastmodifieddate as timestamp)                      as updated_at
    from source

)

select * from renamed
