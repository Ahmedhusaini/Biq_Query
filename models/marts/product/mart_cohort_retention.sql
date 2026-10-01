-- Monthly cohort retention: of the customers who started in month X,
-- what share were still active (>=1 product event) N months later?
-- Classic triangle chart for the Product team.

with cohorts as (

    select
        contact_id                                      as user_id,
        {{ month_of('first_subscription_at') }}         as cohort_month
    from {{ ref('dim_contacts') }}
    where first_subscription_at is not null

),

cohort_sizes as (

    select cohort_month, count(*) as cohort_size
    from cohorts
    group by 1

),

activity as (

    select distinct
        user_id,
        {{ month_of('event_date') }} as activity_month
    from {{ ref('fct_product_events') }}

),

retained as (

    select
        c.cohort_month,
        {{ dbt.datediff('c.cohort_month', 'a.activity_month', 'month') }} as months_since_start,
        count(distinct a.user_id)                                          as active_users
    from cohorts  as c
    inner join activity as a
        on c.user_id = a.user_id
        and a.activity_month >= c.cohort_month
    group by 1, 2

)

select
    r.cohort_month,
    r.months_since_start,
    s.cohort_size,
    r.active_users,
    round(cast(r.active_users as {{ dbt.type_float() }}) / s.cohort_size, 4) as retention_rate
from retained as r
inner join cohort_sizes as s
    on r.cohort_month = s.cohort_month
