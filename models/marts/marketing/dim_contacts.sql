-- The CRM "single source of truth": one row per active contact.
-- Marketing, Sales and Product all read contacts from here, never from raw HubSpot.

select
    contact_id,
    email,
    company_name,
    channel,
    utm_campaign,
    lifecycle_stage,
    created_at,
    created_month,
    is_lead,
    is_mql,
    is_sql,
    is_customer,
    first_won_at,
    first_subscription_at,
    current_mrr_eur,
    current_mrr_eur > 0 as is_paying
from {{ ref('int_contacts__funnel') }}
