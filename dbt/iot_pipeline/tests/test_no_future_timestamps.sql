/*
    Ensure no sensor readings have timestamps in the future.
    A future timestamp indicates clock drift or data corruption on the device.
*/

select
    reading_id,
    device_id,
    reading_ts,
    current_timestamp() as check_time
from {{ ref('stg_sensor_readings') }}
where reading_ts > dateadd(hour, 1, current_timestamp())
