{{
    config(
        materialized='view',
        schema='data_vault'
    )
}}

/*
    COMPARISON QUERY: Same question answered by all 4 modeling approaches.

    Question: "What's the average temperature per cluster for the last 24 hours?"

    This view uses the Data Vault approach. Compare the SQL complexity:

    ┌─────────────────┬──────────────────────────────────────────┬────────┐
    │ Approach         │ JOINs needed                             │ Lines  │
    ├─────────────────┼──────────────────────────────────────────┼────────┤
    │ Star Schema      │ fct → dim_devices                        │ ~8     │
    │ Snowflake Schema │ fct → dim_device → dim_cluster           │ ~12    │
    │ Data Vault       │ link → hub → sat_metrics + sat_details   │ ~20    │
    │ OBT              │ None (everything in one table)           │ ~5     │
    └─────────────────┴──────────────────────────────────────────┴────────┘
*/

-- Data Vault version (most JOINs):
with reading_metrics as (
    select * from {{ ref('sat_reading_metrics') }}
),

device_details as (
    select * from {{ ref('sat_device_details') }}
),

links as (
    select * from {{ ref('link_device_reading') }}
),

hub_devices as (
    select * from {{ ref('hub_device') }}
),

device_registry as (
    select * from {{ ref('device_registry') }}
)

select
    dr.cluster_id,
    round(avg(rm.temperature), 2) as avg_temperature,
    count(*) as reading_count
from reading_metrics rm
inner join links l on rm.hub_reading_hk = l.hub_reading_hk
inner join hub_devices hd on l.hub_device_hk = hd.hub_device_hk
inner join device_registry dr on hd.device_id = dr.device_id
where rm.reading_ts >= dateadd(hour, -24, current_timestamp())
group by dr.cluster_id
order by dr.cluster_id
