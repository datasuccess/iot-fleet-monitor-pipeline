{{
    config(
        materialized='incremental',
        unique_key='link_device_reading_hk',
        schema='data_vault'
    )
}}

/*
    LINK: Device <-> Reading

    Links capture the RELATIONSHIP between two business entities.
    "Device X produced Reading Y at time Z"

    Links contain:
    - Hash key of the link itself (combo of both business keys)
    - Hash keys pointing to both Hubs
    - Load metadata

    NO descriptive data — just the relationship.
*/

with source as (
    select distinct
        device_id,
        reading_id,
        reading_ts
    from {{ ref('stg_sensor_readings') }}
    where device_id is not null and reading_id is not null
),

hashed as (
    select
        {{ dbt_utils.generate_surrogate_key(['device_id', 'reading_id']) }} as link_device_reading_hk,
        {{ dbt_utils.generate_surrogate_key(['device_id']) }} as hub_device_hk,
        {{ dbt_utils.generate_surrogate_key(['reading_id']) }} as hub_reading_hk,
        device_id,
        reading_id,
        reading_ts,
        current_timestamp() as load_ts,
        'iot_pipeline' as record_source
    from source
)

select * from hashed
{% if is_incremental() %}
where link_device_reading_hk not in (select link_device_reading_hk from {{ this }})
{% endif %}
