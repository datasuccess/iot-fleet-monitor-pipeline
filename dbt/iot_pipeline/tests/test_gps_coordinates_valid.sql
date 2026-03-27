/*
    Ensure GPS coordinates are within valid ranges.
    Latitude: -90 to 90, Longitude: -180 to 180.
*/

select
    device_id,
    latitude,
    longitude
from {{ ref('dim_devices') }}
where latitude < -90 or latitude > 90
   or longitude < -180 or longitude > 180
