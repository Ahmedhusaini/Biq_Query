{{
    config(
        materialized = 'incremental',
        unique_key = 'event_id',
        incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
        on_schema_change = 'append_new_columns',
        partition_by = (
            {'field': 'event_date', 'data_type': 'date', 'granularity': 'day'}
            if target.type == 'bigquery' else none
        ),
        cluster_by = (['user_id', 'event_name'] if target.type == 'bigquery' else none)
    )
}}

-- Largest table in the project, so it is incremental:
--  * first run / --full-refresh: builds everything
--  * later runs: only re-processes the last N days (var event_lookback_days)
--    to catch late-arriving events; unique_key + merge prevents duplicates
--  * on BigQuery: partitioned by day + clustered, so dashboards filtered by
--    date/user only scan what they need (cost + speed)

with events as (

    select * from {{ ref('stg_product__events') }}

    {% if is_incremental() %}
    where event_at >= (
        select cast({{ dbt.dateadd('day', -1 * var('event_lookback_days'), 'max(event_at)') }} as timestamp)
        from {{ this }}
    )
    {% endif %}

)

select
    e.event_id,
    e.user_id,
    e.event_name,
    e.event_at,
    e.event_date,
    c.channel     as user_channel,
    e.event_name in ('course_created', 'lesson_published', 'video_uploaded') as is_creator_action
from events as e
left join {{ ref('dim_contacts') }} as c
    on e.user_id = c.contact_id
