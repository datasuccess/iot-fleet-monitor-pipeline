{{
    config(
        materialized='incremental',
        unique_key='hub_device_hk',
        schema='data_vault'
    )
}}

/*
    HUB: Device
    Business key: device_id

    Hubs store ONLY the business key + metadata about when it was first seen.
    No descriptive attributes — those go in Satellites.
    A device appears here exactly ONCE, the first time we ever see it.
*/

with source as (
    select distinct
        device_id
    from {{ ref('stg_sensor_readings') }}
    where device_id is not null
),

hashed as (
    select
        {{ dbt_utils.generate_surrogate_key(['device_id']) }} as hub_device_hk,
        device_id,
        current_timestamp() as load_ts,
        'iot_pipeline' as record_source
    from source
)

select * from hashed
{% if is_incremental() %}
where hub_device_hk not in (select hub_device_hk from {{ this }})
{% endif %}
