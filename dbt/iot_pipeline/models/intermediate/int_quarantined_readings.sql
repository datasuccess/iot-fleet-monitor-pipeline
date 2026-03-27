{{
    config(
        materialized='incremental',
        unique_key='reading_id',
        incremental_strategy='merge'
    )
}}

/*
    Quarantine bad readings with rejection reasons.
    Any reading with validation_error_count > 0 ends up here.
    Stored separately for debugging and data quality reporting.
*/

with validated as (
    select * from {{ ref('int_readings_validated') }}
    where validation_error_count > 0
    {% if is_incremental() %}
    and loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
)

select
    reading_id,
    device_id,
    reading_ts,
    temperature,
    humidity,
    pressure,
    battery_pct,
    latitude,
    longitude,
    firmware_version,
    error_profile,
    loaded_at,
    source_file,

    -- Rejection reasons as array
    array_construct_compact(
        case when not is_temperature_valid then 'TEMPERATURE_OUT_OF_RANGE' end,
        case when not is_humidity_valid then 'HUMIDITY_OUT_OF_RANGE' end,
        case when not is_pressure_valid then 'PRESSURE_OUT_OF_RANGE' end,
        case when not is_battery_valid then 'BATTERY_OUT_OF_RANGE' end,
        case when is_anomaly then 'ZSCORE_ANOMALY' end
    ) as rejection_reasons,

    validation_error_count,
    current_timestamp() as quarantined_at

from validated
