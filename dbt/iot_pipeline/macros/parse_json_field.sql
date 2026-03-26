/*
    Safe VARIANT extraction macro.
    Extracts a field from a VARIANT column with TRY_CAST to the specified type.
    Returns NULL if the field doesn't exist or can't be cast.

    Usage:
        {{ parse_json_field('raw_data', 'temperature', 'float') }}
        → TRY_CAST(raw_data:temperature AS FLOAT)
*/

{% macro parse_json_field(variant_column, field_name, cast_type='varchar') -%}
    try_cast({{ variant_column }}:{{ field_name }} as {{ cast_type }})
{%- endmacro %}
