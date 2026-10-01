-- Singular test: the current month's paying customers in the finance mart must
-- match the number of paying contacts in dim_contacts. Two teams, one number.
with finance as (
    select paying_customers
    from {{ ref('fct_mrr_monthly') }}
    where month_start = (select max(month_start) from {{ ref('fct_mrr_monthly') }})
),
crm as (
    select count(*) as paying_customers
    from {{ ref('dim_contacts') }}
    where is_paying
)
select f.paying_customers as finance_count, c.paying_customers as crm_count
from finance as f
cross join crm as c
where f.paying_customers != c.paying_customers
