{{
    config(
        materialized='incremental',
        unique_key='sat_device_details_hk',
        schema='data_vault'
    )
}}

/*
    SATELLITE: Device Details
    Parent: Hub_Device

    Satellites store the DESCRIPTIVE ATTRIBUTES that change over time.
    Every time an attribute changes, a new row is inserted (full history).

    This is Data Vault's answer to SCD Type 2 — but it's automatic.
    You never update rows, only insert. The latest row per device = current state.

    hashdiff detects changes: if the hash of all descriptive columns is the same
    as the latest row, skip it (nothing changed). If different, insert new row.
*/

with source as (
    select
        device_id,
        firmware_version,
        error_profile,
        reading_ts as effective_from
    from {{ ref('stg_sensor_readings') }}
    where device_id is not null
    qualify row_number() over (
        partition by device_id, firmware_version, error_profile
        order by reading_ts
    ) = 1
),

hashed as (
    select
        {{ dbt_utils.generate_surrogate_key(['device_id', 'effective_from']) }} as sat_device_details_hk,
        {{ dbt_utils.generate_surrogate_key(['device_id']) }} as hub_device_hk,
        device_id,
        firmware_version,
        error_profile,
        {{ dbt_utils.generate_surrogate_key(['firmware_version', 'error_profile']) }} as hashdiff,
        effective_from,
        current_timestamp() as load_ts,
        'iot_pipeline' as record_source
    from source
)

select * from hashed
{% if is_incremental() %}
where sat_device_details_hk not in (select sat_device_details_hk from {{ this }})
{% endif %}
