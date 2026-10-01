{# Custom generic tests: return rows that FAIL. Zero rows = pass. #}

{% test non_negative(model, column_name) %}
select *
from {{ model }}
where {{ column_name }} < 0
{% endtest %}


{% test not_in_future(model, column_name) %}
select *
from {{ model }}
where {{ column_name }} > {{ dbt.current_timestamp() }}
{% endtest %}


{# Grain test: the listed columns together identify exactly one row
   (what dbt_utils.unique_combination_of_columns does, without the package). #}
{% test unique_combination(model, columns) %}
select {{ columns | join(', ') }}, count(*) as n
from {{ model }}
group by {{ columns | join(', ') }}
having count(*) > 1
{% endtest %}
