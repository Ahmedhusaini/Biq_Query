-- Staging: one clean row per HubSpot contact.
--  * dedup: the loader can deliver several versions of a contact -> keep the latest
--  * clean: normalise emails, rename to snake_case, cast types
--  * no business logic here - that belongs in intermediate / marts

with source as (

    select * from {{ source('hubspot', 'contacts') }}

),

renamed as (

    select
        cast(contact_id as {{ dbt.type_bigint() }})         as contact_id,
        lower(trim(email))                                  as email,
        firstname                                           as first_name,
        company                                             as company_name,
        lifecyclestage                                      as lifecycle_stage,
        hs_analytics_source                                 as original_source,
        {{ channel_from_hubspot_source('hs_analytics_source') }} as channel,
        nullif(utm_campaign, '')                            as utm_campaign,
        cast(createdate as timestamp)                       as created_at,
        cast(lastmodifieddate as timestamp)                 as updated_at,
        coalesce(is_deleted, false)                         as is_deleted
    from source

),

deduplicated as (

    select *
    from renamed
    where contact_id is not null
    qualify row_number() over (
        partition by contact_id
        order by updated_at desc
    ) = 1

)

select * from deduplicated
