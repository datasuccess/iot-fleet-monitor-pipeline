{{
    config(
        materialized='incremental',
        unique_key='sat_reading_metrics_hk',
        schema='data_vault'
    )
}}

/*
    SATELLITE: Reading Metrics
    Parent: Hub_Sensor_Reading

    The actual sensor measurements for each reading.
    Since sensor readings don't change (they're events, not state),
    each reading gets exactly one satellite row.

    In Data Vault, even immutable data goes through the same pattern.
    This consistency is the point — every data type follows identical rules.
*/

with source as (
    select
        reading_id,
        device_id,
        reading_ts,
        temperature,
        humidity,
        pressure,
        battery_pct,
        latitude,
        longitude
    from {{ ref('stg_sensor_readings') }}
    where reading_id is not null
    qualify row_number() over (partition by reading_id order by reading_ts) = 1
),

hashed as (
    select
        {{ dbt_utils.generate_surrogate_key(['reading_id']) }} as sat_reading_metrics_hk,
        {{ dbt_utils.generate_surrogate_key(['reading_id']) }} as hub_reading_hk,
        reading_id,
        device_id,
        reading_ts,
        temperature,
        humidity,
        pressure,
        battery_pct,
        latitude,
        longitude,
        {{ dbt_utils.generate_surrogate_key([
            'temperature', 'humidity', 'pressure', 'battery_pct', 'latitude', 'longitude'
        ]) }} as hashdiff,
        current_timestamp() as load_ts,
        'iot_pipeline' as record_source
    from source
)

select * from hashed
{% if is_incremental() %}
where sat_reading_metrics_hk not in (select sat_reading_metrics_hk from {{ this }})
{% endif %}
