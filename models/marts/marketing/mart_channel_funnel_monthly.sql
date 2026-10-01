-- Marketing funnel by acquisition channel and sign-up month.
-- Feeds the Looker Studio "Marketing Funnel" page. Pre-aggregated so the
-- dashboard reads a few hundred rows instead of scanning contacts each time.

with funnel as (

    select * from {{ ref('int_contacts__funnel') }}

),

aggregated as (

    select
        created_month,
        channel,
        count(*)                                                   as contacts,
        sum(case when is_lead     then 1 else 0 end)               as leads,
        sum(case when is_mql      then 1 else 0 end)               as mqls,
        sum(case when is_sql      then 1 else 0 end)               as sqls,
        sum(case when is_customer then 1 else 0 end)               as customers,
        sum(won_amount_eur)                                        as won_amount_eur,
        avg(case when is_customer then days_to_close end)          as avg_days_to_close
    from funnel
    group by 1, 2

)

select
    *,
    -- divide-by-zero safe ratios
    round(cast(mqls      as {{ dbt.type_float() }}) / nullif(leads, 0), 4)    as lead_to_mql_rate,
    round(cast(customers as {{ dbt.type_float() }}) / nullif(contacts, 0), 4) as contact_to_customer_rate
from aggregated
