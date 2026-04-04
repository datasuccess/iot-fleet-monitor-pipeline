{{
    config(
        materialized='incremental',
        unique_key='hourly_reading_id',
        incremental_strategy='merge'
    )
}}

/*
    Aggregated hourly metrics per device.
    One row per (device_id, reading_hour).
*/

with enriched as (
    select * from {{ ref('int_readings_enriched') }}
    {% if is_incremental() %}
    where reading_ts > (select max(reading_hour) from {{ this }})
    {% endif %}
)

select
    {{ dbt_utils.generate_surrogate_key(['device_id', "date_trunc('hour', reading_ts)"]) }} as hourly_reading_id,
    device_id,
    date_trunc('hour', reading_ts) as reading_hour,

    -- Temperature stats
    avg(temperature) as avg_temperature,
    min(temperature) as min_temperature,
    max(temperature) as max_temperature,
    stddev(temperature) as stddev_temperature,

    -- Humidity stats
    avg(humidity) as avg_humidity,
    min(humidity) as min_humidity,
    max(humidity) as max_humidity,

    -- Pressure stats
    avg(pressure) as avg_pressure,

    -- CO2 stats (NULL for devices without CO2 sensor)
    avg(co2_level) as avg_co2_level,
    min(co2_level) as min_co2_level,
    max(co2_level) as max_co2_level,

    -- Battery
    avg(battery_pct) as avg_battery_pct,
    min(battery_pct) as min_battery_pct,

    -- Counts
    count(*) as reading_count,
    count(case when temperature_zscore is not null and abs(temperature_zscore) > 3 then 1 end) as anomaly_count,

    -- Metadata
    max(cluster_id) as cluster_id,
    max(device_type) as device_type

from enriched
group by 1, 2, 3
