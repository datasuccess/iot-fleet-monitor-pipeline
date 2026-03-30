{{
    config(
        materialized='table',
        schema='snowflake_schema'
    )
}}

/*
    SNOWFLAKE SCHEMA: Cluster Dimension (normalized from dim_devices)

    In Star Schema: cluster_id, base_latitude, base_longitude all live in dim_devices.
    In Snowflake Schema: we normalize these into their own dimension table.

    Why normalize?
    - No data redundancy: cluster info stored once, not repeated per device
    - Cleaner updates: change a cluster city → update 1 row, not 10 device rows
    - Referential integrity: cluster_id is a real FK, not just a string

    Why NOT normalize?
    - Queries need more JOINs: fct → dim_device → dim_cluster (2 hops instead of 1)
    - Slower in analytical databases (Snowflake is optimized for wide, denormalized scans)
    - More complex for analysts to understand the model
*/

with clusters as (
    select distinct
        cluster_id,
        base_latitude as cluster_latitude,
        base_longitude as cluster_longitude,
        case cluster_id
            when 'FACTORY_A' then 'New York'
            when 'FACTORY_B' then 'Los Angeles'
            when 'WAREHOUSE_A' then 'Chicago'
            when 'WAREHOUSE_B' then 'Houston'
            when 'OUTDOOR' then 'Seattle'
        end as cluster_city,
        case cluster_id
            when 'FACTORY_A' then 'America/New_York'
            when 'FACTORY_B' then 'America/Los_Angeles'
            when 'WAREHOUSE_A' then 'America/Chicago'
            when 'WAREHOUSE_B' then 'America/Chicago'
            when 'OUTDOOR' then 'America/Los_Angeles'
        end as cluster_timezone,
        case
            when cluster_id like 'FACTORY%' then 'Manufacturing'
            when cluster_id like 'WAREHOUSE%' then 'Storage'
            else 'Field'
        end as cluster_category
    from {{ ref('device_registry') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['cluster_id']) }} as cluster_sk,
    *
from clusters
