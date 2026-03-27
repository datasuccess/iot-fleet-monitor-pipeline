{% macro safe_cast_numeric(field, precision=10, scale=2) %}
/*
    Safely casts a VARIANT or string field to a numeric type.
    Returns NULL instead of erroring on invalid values.

    Usage:
        {{ safe_cast_numeric('raw:temperature') }}
        {{ safe_cast_numeric('raw:pressure', precision=12, scale=4) }}
*/
try_cast({{ field }} as number({{ precision }}, {{ scale }}))
{% endmacro %}
