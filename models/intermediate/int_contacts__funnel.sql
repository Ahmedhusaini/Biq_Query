-- One row per (non-deleted) contact with funnel flags and revenue facts joined in.
--
-- Simplification: HubSpot only exposes the *current* lifecycle stage here, so we
-- treat "reached stage X" as "current stage is X or later". In a real HubSpot
-- setup you would use the hs_lifecyclestage_<stage>_date properties (or the
-- contacts snapshot in snapshots/) to get the exact date each stage was reached.

with contacts as (

    select * from {{ ref('stg_hubspot__contacts') }}
    where not is_deleted

),

stage_rank as (

    select
        *,
        case lifecycle_stage
            when 'subscriber'             then 1
            when 'lead'                   then 2
            when 'marketingqualifiedlead' then 3
            when 'salesqualifiedlead'     then 4
            when 'opportunity'            then 5
            when 'customer'               then 6
        end as stage_rank
    from contacts

),

won_deals as (

    select
        contact_id,
        min(closed_at)  as first_won_at,
        sum(amount_eur) as won_amount_eur
    from {{ ref('stg_hubspot__deals') }}
    where deal_status = 'won'
    group by 1

),

subscriptions as (

    select
        contact_id,
        min(started_at)                                             as first_subscription_at,
        sum(case when not is_cancelled then mrr_eur else 0 end)     as current_mrr_eur
    from {{ ref('stg_billing__subscriptions') }}
    group by 1

)

select
    c.contact_id,
    c.email,
    c.company_name,
    c.channel,
    c.utm_campaign,
    c.lifecycle_stage,
    c.created_at,
    {{ month_of('c.created_at') }}      as created_month,

    c.stage_rank >= 2                   as is_lead,
    c.stage_rank >= 3                   as is_mql,
    c.stage_rank >= 4                   as is_sql,
    c.stage_rank >= 5                   as is_opportunity,
    c.stage_rank = 6                    as is_customer,

    w.first_won_at,
    coalesce(w.won_amount_eur, 0)       as won_amount_eur,
    s.first_subscription_at,
    coalesce(s.current_mrr_eur, 0)      as current_mrr_eur,
    {{ dbt.datediff('c.created_at', 'w.first_won_at', 'day') }} as days_to_close

from stage_rank as c
left join won_deals     as w on c.contact_id = w.contact_id
left join subscriptions as s on c.contact_id = s.contact_id
