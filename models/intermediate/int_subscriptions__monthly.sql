-- One row per subscription per month it touched, with MRR movement flags.
-- Month spine x subscriptions: the classic way to turn start/end dates into a time series.

with month_bounds as (

    select * from {{ ref('int_months') }}

),

subs as (

    select * from {{ ref('stg_billing__subscriptions') }}

)

select
    m.month_start,
    s.subscription_id,
    s.contact_id,
    s.plan,
    s.mrr_eur,

    -- active on the last day of the month
    (s.started_at < cast(m.next_month_start as timestamp)
        and (s.cancelled_at is null or s.cancelled_at >= cast(m.next_month_start as timestamp)))
                                                                      as is_active_end_of_month,
    -- started during the month
    (s.started_at >= cast(m.month_start as timestamp)
        and s.started_at < cast(m.next_month_start as timestamp))     as is_new,
    -- cancelled during the month
    coalesce(s.cancelled_at >= cast(m.month_start as timestamp)
        and s.cancelled_at < cast(m.next_month_start as timestamp), false) as is_churned

from month_bounds as m
inner join subs as s
    on  s.started_at < cast(m.next_month_start as timestamp)
    and (s.cancelled_at is null or s.cancelled_at >= cast(m.month_start as timestamp))
