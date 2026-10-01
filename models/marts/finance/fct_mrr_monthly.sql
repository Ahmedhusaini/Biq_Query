-- MRR bridge per month:  opening MRR + new MRR - churned MRR = closing MRR
-- The singular test tests/assert_mrr_bridge_reconciles.sql checks this holds.

with months as (

    select month_start from {{ ref('int_months') }}

),

subs as (

    select * from {{ ref('int_subscriptions__monthly') }}

),

monthly as (

    -- left join from the calendar so months without any movement still appear
    select
        m.month_start,
        sum(case when is_active_end_of_month then mrr_eur else 0 end) as closing_mrr_eur,
        sum(case when is_new                 then mrr_eur else 0 end) as new_mrr_eur,
        sum(case when is_churned             then mrr_eur else 0 end) as churned_mrr_eur,
        count(distinct case when is_active_end_of_month then contact_id end) as paying_customers,
        count(distinct case when is_new     then contact_id end)             as new_customers,
        count(distinct case when is_churned then contact_id end)             as churned_customers
    from months as m
    left join subs as s
        on m.month_start = s.month_start
    group by 1

)

select
    month_start,
    coalesce(lag(closing_mrr_eur) over (order by month_start), 0) as opening_mrr_eur,
    new_mrr_eur,
    churned_mrr_eur,
    closing_mrr_eur,
    paying_customers,
    new_customers,
    churned_customers,
    closing_mrr_eur * 12                                          as arr_eur,
    round(cast(churned_customers as {{ dbt.type_float() }})
          / nullif(lag(paying_customers) over (order by month_start), 0), 4) as logo_churn_rate
from monthly
