/*
    Flag sensor readings with timestamps far in the future.
    Allows up to 24h ahead (late arrival error injection can shift timestamps).
    Only flags readings more than 24 hours in the future — true clock drift.
*/

{{ config(severity='warn') }}

select
    reading_id,
    device_id,
    reading_ts,
    current_timestamp() as check_time
from {{ ref('stg_sensor_readings') }}
where reading_ts > dateadd(day, 1, current_timestamp())
