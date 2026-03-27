{{
    config(
        materialized='incremental',
        unique_key='device_health_id',
        incremental_strategy='merge'
    )
}}

/*
    Daily device health metrics.
    Tracks battery trends, uptime, and alert status per device per day.
*/

with enriched as (
    select * from {{ ref('int_readings_enriched') }}
    {% if is_incremental() %}
    where reading_ts::date > (select max(report_date) from {{ this }})
    {% endif %}
),

daily_stats as (
    select
        device_id,
        reading_ts::date as report_date,

        -- Battery
        avg(battery_pct) as avg_battery_pct,
        min(battery_pct) as min_battery_pct,
        max(battery_pct) as max_battery_pct,

        -- Battery drain rate: difference between first and last reading / hours
        (max_by(battery_pct, reading_ts) - min_by(battery_pct, reading_ts))
            / nullif(timestampdiff(hour, min(reading_ts), max(reading_ts)), 0) as battery_drain_rate,

        -- Uptime: readings received vs expected (12 per hour × 24 hours = 288)
        count(*) as readings_received,
        288 as readings_expected,
        round(count(*) / 288.0 * 100, 2) as uptime_pct,

        -- Alerts
        count(case when battery_pct < 15 then 1 end) as low_battery_alerts,
        count(case when abs(temperature_zscore) > 3 then 1 end) as anomaly_alerts

    from enriched
    group by 1, 2
)

select
    {{ dbt_utils.generate_surrogate_key(['device_id', 'report_date']) }} as device_health_id,
    device_id,
    report_date,
    avg_battery_pct,
    min_battery_pct,
    max_battery_pct,
    battery_drain_rate,
    readings_received,
    readings_expected,
    uptime_pct,
    low_battery_alerts + anomaly_alerts as alert_count,

    case
        when uptime_pct < 50 or min_battery_pct < 5 then 'critical'
        when uptime_pct < 80 or min_battery_pct < 15 or anomaly_alerts > 5 then 'warning'
        else 'healthy'
    end as health_status

from daily_stats
