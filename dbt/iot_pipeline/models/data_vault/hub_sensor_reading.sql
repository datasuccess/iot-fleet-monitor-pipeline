{{
    config(
        materialized='incremental',
        unique_key='hub_reading_hk',
        schema='data_vault'
    )
}}

/*
    HUB: Sensor Reading
    Business key: reading_id

    Each unique reading gets one row, forever.
    The actual sensor values live in Satellite tables.
*/

with source as (
    select distinct
        reading_id
    from {{ ref('stg_sensor_readings') }}
    where reading_id is not null
),

hashed as (
    select
        {{ dbt_utils.generate_surrogate_key(['reading_id']) }} as hub_reading_hk,
        reading_id,
        current_timestamp() as load_ts,
        'iot_pipeline' as record_source
    from source
)

select * from hashed
{% if is_incremental() %}
where hub_reading_hk not in (select hub_reading_hk from {{ this }})
{% endif %}
