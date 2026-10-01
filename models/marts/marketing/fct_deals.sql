select
    d.deal_id,
    d.contact_id,
    c.channel,
    c.utm_campaign,
    d.plan,
    d.deal_stage,
    d.deal_status,
    d.amount_eur,
    d.created_at,
    d.closed_at,
    {{ month_of('d.created_at') }}                               as created_month,
    {{ dbt.datediff('d.created_at', 'd.closed_at', 'day') }}      as days_to_close
from {{ ref('stg_hubspot__deals') }} as d
left join {{ ref('dim_contacts') }}  as c
    on d.contact_id = c.contact_id
