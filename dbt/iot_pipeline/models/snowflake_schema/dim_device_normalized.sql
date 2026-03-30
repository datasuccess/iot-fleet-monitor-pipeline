{{
    config(
        materialized='table',
        schema='snowflake_schema'
    )
}}

/*
    SNOWFLAKE SCHEMA: Device Dimension (normalized)

    Compare to Star Schema's dim_devices:
    - Star: device_id, device_name, device_type, cluster_id, base_lat, base_lon, ...
    - Snowflake: device_id, device_name, device_type_sk (FK), cluster_sk (FK), ...

    The device_type and cluster details live in their own tables.
    This device table only stores what's unique to each individual device.
*/

with devices as (
    select * from {{ ref('device_registry') }}
),

metadata as (
    select * from {{ ref('stg_device_metadata') }}
),

clusters as (
    select * from {{ ref('dim_cluster') }}
),

device_types as (
    select * from {{ ref('dim_device_type') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['d.device_id']) }} as device_sk,
    d.device_id,
    d.device_name,

    -- Foreign keys to normalized dimensions (instead of inline attributes)
    dt.device_type_sk,
    c.cluster_sk,

    -- Device-specific attributes (not shared with other devices)
    d.install_date,
    coalesce(m.firmware_version, 'unknown') as firmware_version,
    m.last_seen_at,
    case
        when m.last_seen_at is null then 'never_seen'
        when timestampdiff(hour, m.last_seen_at, current_timestamp()) > 24 then 'offline'
        when timestampdiff(hour, m.last_seen_at, current_timestamp()) > 6 then 'inactive'
        else 'active'
    end as device_status

from devices d
left join metadata m on d.device_id = m.device_id
left join clusters c on d.cluster_id = c.cluster_id
left join device_types dt on d.device_type = dt.device_type
