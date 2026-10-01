-- SQL patterns that come up in analytics-engineering interviews, run on this project's models.
-- Compile with `dbt compile -s sql_interview_practice`, then paste the compiled SQL
-- from target/compiled/ into DuckDB or the BigQuery console.

-- 1) Deduplicate: latest record per key  (ROW_NUMBER + QUALIFY)
select *
from {{ ref('stg_hubspot__contacts') }}
qualify row_number() over (partition by email order by updated_at desc) = 1;

-- 2) Running total: cumulative won revenue per channel over time
select
    channel,
    created_month,
    sum(won_amount_eur) as won_eur,
    sum(sum(won_amount_eur)) over (partition by channel order by created_month) as cumulative_won_eur
from {{ ref('mart_channel_funnel_monthly') }}
group by 1, 2;

-- 3) Month-over-month growth with LAG
select
    month_start,
    closing_mrr_eur,
    round(100.0 * (closing_mrr_eur - lag(closing_mrr_eur) over (order by month_start))
          / nullif(lag(closing_mrr_eur) over (order by month_start), 0), 1) as mrr_growth_pct
from {{ ref('fct_mrr_monthly') }};

-- 4) 7-day rolling average of daily active users
select
    event_date,
    daily_active_users,
    avg(daily_active_users) over (order by event_date rows between 6 preceding and current row) as dau_7d_avg
from {{ ref('fct_daily_active_users') }};

-- 5) Top 3 most active customers per acquisition channel (ranking within groups)
select *
from (
    select
        user_channel,
        user_id,
        count(*) as events,
        dense_rank() over (partition by user_channel order by count(*) desc) as rnk
    from {{ ref('fct_product_events') }}
    group by 1, 2
) ranked
where rnk <= 3;

-- 6) Gaps: customers with no product activity in their last 30 days (churn risk)
select c.contact_id, c.email, max(e.event_at) as last_seen_at
from {{ ref('dim_contacts') }} as c
left join {{ ref('fct_product_events') }} as e on c.contact_id = e.user_id
where c.is_paying
group by 1, 2
having max(e.event_at) is null
    or max(e.event_at) < {{ dbt.dateadd('day', -30, dbt.current_timestamp()) }};
