-- Daily product engagement KPIs.

select
    event_date,
    count(distinct user_id)                                               as daily_active_users,
    count(distinct case when is_creator_action then user_id end)          as daily_active_creators,
    count(*)                                                              as events,
    round(cast(count(*) as {{ dbt.type_float() }})
          / nullif(count(distinct user_id), 0), 2)                        as events_per_active_user
from {{ ref('fct_product_events') }}
group by 1
