{{
    config(
        materialized='incremental',
        unique_key='reading_id',
        incremental_strategy='merge',
        schema='snowflake_schema'
    )
}}

/*
    SNOWFLAKE SCHEMA: Fact Table (normalized)

    Compare to Star Schema's fct_hourly_readings:
    - Star: device_id (string), all device attrs available via 1 JOIN to dim_devices
    - Snowflake: device_sk (surrogate key), device attrs require 3 JOINs
                 (fct → dim_device → dim_cluster AND dim_device → dim_device_type)

    The fact table uses SURROGATE KEYS (integers/hashes) instead of business keys.
    This is a key difference:
    - Star Schema: JOIN on device_id (varchar) — readable but slower
    - Snowflake Schema: JOIN on device_sk (hash) — faster JOINs, less readable

    Query example:
    SELECT d.device_name, c.cluster_city, dt.type_description, f.temperature
    FROM fct_readings_normalized f
    JOIN dim_device_normalized d ON f.device_sk = d.device_sk
    JOIN dim_cluster c ON d.cluster_sk = c.cluster_sk
    JOIN dim_device_type dt ON d.device_type_sk = dt.device_type_sk
    -- 3 JOINs instead of 1!
*/

with enriched as (
    select * from {{ ref('int_readings_enriched') }}
    {% if is_incremental() %}
    where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
),

devices as (
    select * from {{ ref('dim_device_normalized') }}
),

time_dim as (
    select * from {{ ref('dim_time') }}
)

select
    e.reading_id,

    -- Surrogate foreign keys (not business keys)
    d.device_sk,
    t.time_sk,

    -- Measures (only numeric facts — no descriptive text)
    e.temperature,
    e.humidity,
    e.pressure,
    e.battery_pct,
    e.latitude,
    e.longitude,
    e.temperature_zscore,

    -- Degenerate dimensions (attributes stored on fact, not worth their own dim)
    e.firmware_version,
    e.error_profile,
    e.reading_ts,
    e.loaded_at,
    e.source_file

from enriched e
left join devices d on e.device_id = d.device_id
left join time_dim t on date_trunc('hour', e.reading_ts) = t.hour_ts
