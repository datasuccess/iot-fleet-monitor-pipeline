{{
    config(
        materialized='table'
    )
}}

/*
    Device dimension — combines seed registry with live metadata.
    SCD Type 2 tracking happens via the snapshot (snap_device_metadata).
*/

with registry as (
    select * from {{ ref('device_registry') }}
),

live_metadata as (
    select * from {{ ref('stg_device_metadata') }}
),

final as (
    select
        r.device_id,
        r.device_name,
        r.device_type,
        r.cluster_id,
        r.base_latitude,
        r.base_longitude,
        r.install_date,
        coalesce(m.firmware_version, r.device_id) as firmware_version,
        m.last_seen_at,
        case
            when m.last_seen_at is null then 'never_seen'
            when timestampdiff(hour, m.last_seen_at, current_timestamp()) > 24 then 'offline'
            when timestampdiff(hour, m.last_seen_at, current_timestamp()) > 6 then 'inactive'
            else 'active'
        end as device_status
    from registry r
    left join live_metadata m on r.device_id = m.device_id
)

select * from final
