{{
    config(
        materialized='incremental',
        unique_key='reading_id',
        incremental_strategy='merge'
    )
}}

/*
    Deduplicate sensor readings using window function.
    Keeps the first occurrence based on loaded_at (earliest load wins).
    Handles exact duplicates from error injection (duplicate_rate).
*/

with source as (
    select * from {{ ref('stg_sensor_readings') }}
    {% if is_incremental() %}
    where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
),

ranked as (
    select
        *,
        row_number() over (
            partition by reading_id
            order by loaded_at asc
        ) as row_num
    from source
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
    signal_strength,
    temp_celsius_renamed,
    loaded_at,
    source_file
from ranked
where row_num = 1
