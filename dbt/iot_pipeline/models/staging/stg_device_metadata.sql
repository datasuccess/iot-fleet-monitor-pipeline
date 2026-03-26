{{
    config(
        materialized='view'
    )
}}

/*
    Extract latest device metadata from raw readings.
    Each device may appear many times — we take the most recent firmware version.
*/

with readings as (
    select
        raw_data:device_id::varchar         as device_id,
        raw_data:firmware_version::varchar   as firmware_version,
        loaded_at
    from {{ source('raw', 'sensor_readings') }}
    where raw_data:device_id is not null
),

latest as (
    select
        device_id,
        firmware_version,
        loaded_at,
        row_number() over (
            partition by device_id
            order by loaded_at desc
        ) as rn
    from readings
)

select
    device_id,
    firmware_version,
    loaded_at as last_seen_at
from latest
where rn = 1
