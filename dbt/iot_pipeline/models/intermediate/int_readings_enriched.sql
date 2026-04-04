{{
    config(
        materialized='incremental',
        unique_key='reading_id',
        incremental_strategy='merge'
    )
}}

/*
    Enrich validated readings with device metadata and time dimensions.
    Only includes readings that passed validation (quarantined ones go elsewhere).
*/

with validated as (
    select * from {{ ref('int_readings_validated') }}
    where validation_error_count = 0
    {% if is_incremental() %}
    and loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
),

devices as (
    select * from {{ ref('device_registry') }}
),

enriched as (
    select
        v.reading_id,
        v.device_id,
        v.reading_ts,
        v.temperature,
        v.humidity,
        v.pressure,
        v.battery_pct,
        v.co2_level,
        v.latitude,
        v.longitude,
        v.firmware_version,
        v.error_profile,
        v.temperature_zscore,
        v.loaded_at,
        v.source_file,

        -- Device metadata
        d.device_type,
        d.cluster_id,
        d.device_name,

        -- Time dimensions
        extract(hour from v.reading_ts) as hour_of_day,
        dayname(v.reading_ts) as day_of_week,
        case when dayofweek(v.reading_ts) in (0, 6) then true else false end as is_weekend,
        case when extract(hour from v.reading_ts) between 8 and 17 then true else false end as is_business_hours

    from validated v
    left join devices d on v.device_id = d.device_id
)

select * from enriched
