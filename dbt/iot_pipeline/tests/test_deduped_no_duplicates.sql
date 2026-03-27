/*
    After deduplication, there should be no duplicate (device_id, reading_ts) pairs.
*/

select
    device_id,
    reading_ts,
    count(*) as row_count
from {{ ref('int_readings_deduped') }}
group by device_id, reading_ts
having count(*) > 1
