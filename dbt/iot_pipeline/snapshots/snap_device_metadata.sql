{% snapshot snap_device_metadata %}

{{
    config(
        target_schema='snapshots',
        unique_key='device_id',
        strategy='check',
        check_cols=['firmware_version', 'cluster_id', 'device_type', 'latitude', 'longitude']
    )
}}

/*
    SCD Type 2 snapshot of device metadata.
    Tracks changes in firmware, location, cluster, and device type over time.
    Each row represents a version of the device's metadata with valid_from / valid_to timestamps.
*/

select
    device_id,
    firmware_version,
    cluster_id,
    device_type,
    latitude,
    longitude,
    loaded_at as metadata_updated_at
from {{ ref('stg_device_metadata') }}

{% endsnapshot %}
