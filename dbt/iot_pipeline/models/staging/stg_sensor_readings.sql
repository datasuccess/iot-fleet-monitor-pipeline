{{
    config(
        materialized='view'
    )
}}

/*
    Parse raw VARIANT JSON into typed columns using TRY_CAST.
    TRY_CAST returns NULL instead of erroring on bad data — safe for dirty data.
    This is the first transformation: raw semi-structured → typed columns.
*/

with source as (
    select
        raw_data,
        loaded_at,
        source_file
    from {{ source('raw', 'sensor_readings') }}
),

parsed as (
    select
        -- Identity
        raw_data:reading_id::varchar                    as reading_id,
        raw_data:device_id::varchar                     as device_id,

        -- Timestamp: TRY_TO_TIMESTAMP handles bad dates gracefully
        try_to_timestamp(
            raw_data:reading_ts::varchar
        )                                               as reading_ts,

        -- Sensor values: VARIANT must go through ::varchar first, then TRY_CAST
        try_cast(raw_data:temperature::varchar as float)         as temperature,
        try_cast(raw_data:humidity::varchar as float)             as humidity,
        try_cast(raw_data:pressure::varchar as float)             as pressure,
        try_cast(raw_data:battery_pct::varchar as float)          as battery_pct,

        -- CO2 (firmware >= 2.0.0 only — NULL for older devices)
        try_cast(raw_data:co2_level::varchar as float)            as co2_level,

        -- GPS
        try_cast(raw_data:latitude::varchar as float)             as latitude,
        try_cast(raw_data:longitude::varchar as float)            as longitude,

        -- Metadata
        raw_data:firmware_version::varchar               as firmware_version,
        raw_data:error_profile::varchar                  as error_profile,

        -- Schema drift fields (may or may not exist)
        try_cast(raw_data:signal_strength::varchar as float)      as signal_strength,
        raw_data:temp_celsius::varchar                   as temp_celsius_renamed,

        -- Load metadata
        loaded_at,
        source_file
    from source
)

select * from parsed
