/*
    Ensure GPS coordinates are within valid ranges.
    Latitude: -90 to 90, Longitude: -180 to 180.
*/

select
    device_id,
    base_latitude,
    base_longitude
from {{ ref('dim_devices') }}
where base_latitude < -90 or base_latitude > 90
   or base_longitude < -180 or base_longitude > 180
