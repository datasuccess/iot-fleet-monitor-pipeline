/*
    Custom schema naming: use the schema name as-is (not prefixed with target schema).

    Default dbt behavior: target_schema + custom_schema → e.g., RAW_STAGING
    Our behavior: just custom_schema → e.g., STAGING

    This ensures dbt writes to IOT_PIPELINE.STAGING, not IOT_PIPELINE.RAW_STAGING.
*/

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
