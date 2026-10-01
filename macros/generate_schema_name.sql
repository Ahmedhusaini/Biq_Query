{#
  By default dbt names custom schemas "<target_schema>_<custom>" (e.g. analytics_marts).
  Here we use the custom name as-is (raw, staging, marts ...) so the BigQuery
  datasets are clean and predictable. Models without a custom schema land in the
  target's default schema.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
