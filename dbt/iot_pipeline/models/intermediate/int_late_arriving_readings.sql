{{
    config(
        materialized='incremental',
        unique_key='reading_id',
        incremental_strategy='merge'
    )
}}

/*
    Identify late-arriving readings.
    A reading is "late" if reading_ts is significantly older than loaded_at.
    Normal delay: < 10 minutes. Late: > 60 minutes.
*/

with deduped as (
    select * from {{ ref('int_readings_deduped') }}
    {% if is_incremental() %}
    where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
),

late_arrivals as (
    select
        reading_id,
        device_id,
        reading_ts,
        loaded_at,
        timestampdiff(minute, reading_ts, loaded_at) as arrival_delay_minutes,
        temperature,
        humidity,
        pressure,
        battery_pct,
        firmware_version,
        error_profile,
        source_file
    from deduped
    where reading_ts is not null
      and timestampdiff(minute, reading_ts, loaded_at) > 60
)

select * from late_arrivals
