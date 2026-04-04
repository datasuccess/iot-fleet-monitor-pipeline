{{
    config(
        materialized='table'
    )
}}

select
    cluster_id,
    cluster_city,
    cluster_state,
    cluster_timezone,
    environment_type,
    manager_name,
    max_devices
from {{ ref('cluster_metadata') }}
