{{
    config(
        materialized='incremental',
        unique_key='reading_id',
        incremental_strategy='merge',
        schema='obt'
    )
}}

/*
    ONE BIG TABLE (OBT) — Everything in a single denormalized table.

    Why OBT?
    - Zero JOINs at query time = fastest possible queries
    - Perfect for BI tools (Looker, Tableau, Streamlit) that struggle with JOINs
    - Snowflake is columnar — unused columns cost nothing at query time
    - Simple for analysts: one table, all columns, filter and go

    Why NOT OBT?
    - Data duplication: device_name repeated on every reading row
    - Updates are expensive: if a device_name changes, update millions of rows
    - Storage overhead (minor in Snowflake due to compression)
    - No clear ownership: one massive table owned by... everyone? no one?

    Best for: analytics/BI layer, ad-hoc exploration, small-medium datasets
    Worst for: systems with frequent dimension changes, strict data governance
*/

with readings as (
    select * from {{ ref('int_readings_enriched') }}
    {% if is_incremental() %}
    where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
),

devices as (
    select * from {{ ref('device_registry') }}
),

thresholds as (
    select * from {{ ref('sensor_thresholds') }}
    where sensor_type = 'temperature'
)

select
    -- Reading identifiers
    r.reading_id,
    r.device_id,
    r.reading_ts,
    r.loaded_at,
    r.source_file,

    -- Sensor measurements (the facts)
    r.temperature,
    r.humidity,
    r.pressure,
    r.battery_pct,
    r.latitude,
    r.longitude,
    r.firmware_version,
    r.error_profile,

    -- Statistical (from intermediate layer)
    r.temperature_zscore,
    case
        when abs(r.temperature_zscore) > 3 then 'critical'
        when abs(r.temperature_zscore) > 2 then 'warning'
        else 'normal'
    end as anomaly_severity,

    -- Device attributes (denormalized — repeated on every row)
    d.device_name,
    d.device_type,
    d.cluster_id,
    d.base_latitude,
    d.base_longitude,
    d.install_date,

    -- Threshold context (denormalized)
    t.min_valid as threshold_min,
    t.max_valid as threshold_max,
    case
        when r.temperature < t.min_valid or r.temperature > t.max_valid then true
        else false
    end as is_out_of_range,

    -- Time dimensions (pre-computed for filtering)
    r.hour_of_day,
    r.day_of_week,
    r.is_weekend,
    r.is_business_hours,
    date_trunc('hour', r.reading_ts) as reading_hour,
    date_trunc('day', r.reading_ts) as reading_date,
    date_trunc('week', r.reading_ts) as reading_week,
    date_trunc('month', r.reading_ts) as reading_month,

    -- Battery status (pre-computed for dashboards)
    case
        when r.battery_pct < 10 then 'critical'
        when r.battery_pct < 20 then 'low'
        when r.battery_pct < 50 then 'medium'
        else 'good'
    end as battery_status,

    -- GPS drift (Snowflake st_distance on geographies, in km)
    round(
        st_distance(
            st_makepoint(r.longitude, r.latitude),
            st_makepoint(d.base_longitude, d.base_latitude)
        ) / 1000,
        2
    ) as gps_drift_km

from readings r
left join devices d on r.device_id = d.device_id
cross join thresholds t
