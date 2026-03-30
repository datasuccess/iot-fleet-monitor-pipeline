{{
    config(
        materialized='table',
        schema='snowflake_schema'
    )
}}

/*
    SNOWFLAKE SCHEMA: Device Type Dimension

    In Star Schema: device_type is a column on dim_devices.
    In Snowflake Schema: it gets its own table with attributes.

    This lets us store device type-specific info (sensor ranges, calibration
    schedules, cost) without repeating it on every device row.
*/

with types as (
    select distinct device_type
    from {{ ref('device_registry') }}
),

enriched as (
    select
        device_type,
        case device_type
            when 'Type_A' then 'Industrial Grade'
            when 'Type_B' then 'Standard'
            when 'Type_C' then 'Economy'
        end as type_description,
        case device_type
            when 'Type_A' then 'high'
            when 'Type_B' then 'medium'
            when 'Type_C' then 'low'
        end as accuracy_tier,
        case device_type
            when 'Type_A' then 90
            when 'Type_B' then 180
            when 'Type_C' then 365
        end as calibration_interval_days,
        case device_type
            when 'Type_A' then 500
            when 'Type_B' then 250
            when 'Type_C' then 100
        end as unit_cost_usd
    from types
)

select
    {{ dbt_utils.generate_surrogate_key(['device_type']) }} as device_type_sk,
    *
from enriched
