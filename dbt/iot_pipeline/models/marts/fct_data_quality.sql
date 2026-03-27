{{
    config(
        materialized='incremental',
        unique_key='quality_id',
        incremental_strategy='merge'
    )
}}

/*
    Data quality scorecard per batch (source file).
    Tracks null rates, OOR rates, duplicate rates, and overall quality score.
*/

with staged as (
    select * from {{ ref('stg_sensor_readings') }}
    {% if is_incremental() %}
    where loaded_at > (select max(batch_ts) from {{ this }})
    {% endif %}
),

deduped as (
    select * from {{ ref('int_readings_deduped') }}
    {% if is_incremental() %}
    where loaded_at > (select max(batch_ts) from {{ this }})
    {% endif %}
),

quarantined as (
    select * from {{ ref('int_quarantined_readings') }}
    {% if is_incremental() %}
    where loaded_at > (select max(batch_ts) from {{ this }})
    {% endif %}
),

late as (
    select * from {{ ref('int_late_arriving_readings') }}
    {% if is_incremental() %}
    where loaded_at > (select max(batch_ts) from {{ this }})
    {% endif %}
),

per_file as (
    select
        source_file,
        max(loaded_at) as batch_ts,
        count(*) as total_records,

        -- Null counts
        count(*) - count(temperature) as null_temperature,
        count(*) - count(humidity) as null_humidity,
        count(*) - count(pressure) as null_pressure,
        count(*) - count(battery_pct) as null_battery,
        (count(*) - count(temperature)
         + count(*) - count(humidity)
         + count(*) - count(pressure)
         + count(*) - count(battery_pct)
        ) as total_null_fields

    from staged
    group by source_file
),

dupe_counts as (
    select
        source_file,
        count(*) as total_before_dedup
    from staged
    group by source_file
),

dedup_counts as (
    select
        source_file,
        count(*) as total_after_dedup
    from deduped
    group by source_file
),

quarantine_counts as (
    select
        source_file,
        count(*) as quarantined_count
    from quarantined
    group by source_file
),

late_counts as (
    select
        source_file,
        count(*) as late_arrival_count
    from late
    group by source_file
)

select
    {{ dbt_utils.generate_surrogate_key(['pf.source_file']) }} as quality_id,
    pf.batch_ts,
    pf.source_file,
    pf.total_records,
    pf.total_null_fields as null_count,
    round(pf.total_null_fields / nullif(pf.total_records * 4.0, 0) * 100, 2) as null_pct,
    coalesce(dc.total_before_dedup - dd.total_after_dedup, 0) as duplicate_count,
    round(coalesce(dc.total_before_dedup - dd.total_after_dedup, 0) / nullif(dc.total_before_dedup * 1.0, 0) * 100, 2) as duplicate_pct,
    coalesce(qc.quarantined_count, 0) as quarantined_count,
    coalesce(lc.late_arrival_count, 0) as late_arrival_count,

    -- Quality score: 100 minus penalties
    greatest(0, round(
        100
        - (pf.total_null_fields / nullif(pf.total_records * 4.0, 0) * 100) * 0.5
        - coalesce(dc.total_before_dedup - dd.total_after_dedup, 0) / nullif(dc.total_before_dedup * 1.0, 0) * 100 * 0.3
        - coalesce(qc.quarantined_count, 0) / nullif(pf.total_records * 1.0, 0) * 100 * 0.2
    , 2)) as quality_score

from per_file pf
left join dupe_counts dc on pf.source_file = dc.source_file
left join dedup_counts dd on pf.source_file = dd.source_file
left join quarantine_counts qc on pf.source_file = qc.source_file
left join late_counts lc on pf.source_file = lc.source_file
