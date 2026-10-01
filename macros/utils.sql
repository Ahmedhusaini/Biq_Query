{#
  Map HubSpot's raw "original source" values to readable marketing channels.
  Kept in one macro so every model uses the same definition of a channel.
#}
{% macro channel_from_hubspot_source(column) %}
    case {{ column }}
        when 'ORGANIC_SEARCH'  then 'Organic Search'
        when 'PAID_SEARCH'     then 'Paid Search'
        when 'PAID_SOCIAL'     then 'Paid Social'
        when 'EMAIL_MARKETING' then 'Email'
        when 'REFERRALS'       then 'Referral'
        when 'DIRECT_TRAFFIC'  then 'Direct'
        else 'Other'
    end
{% endmacro %}


{# Month start as a DATE, portable across DuckDB and BigQuery. #}
{% macro month_of(column) %}
    cast({{ dbt.date_trunc('month', column) }} as date)
{% endmacro %}
