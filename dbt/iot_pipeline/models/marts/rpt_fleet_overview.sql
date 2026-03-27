{{
    config(
        materialized='table'
    )
}}

/*
    Executive summary — fleet-wide health per day.
    One row per day with high-level KPIs.
*/

with device_health as (
    select * from {{ ref('fct_device_health') }}
),

data_quality as (
    select * from {{ ref('fct_data_quality') }}
),

anomalies as (
    select * from {{ ref('fct_anomalies') }}
),

daily_health as (
    select
        report_date,
        count(distinct device_id) as active_devices,
        sum(readings_received) as total_readings,
        round(avg(uptime_pct), 2) as fleet_uptime_pct,
        round(avg(avg_battery_pct), 2) as fleet_avg_battery,
        count(case when health_status = 'critical' then 1 end) as critical_devices,
        count(case when health_status = 'warning' then 1 end) as warning_devices,
        count(case when min_battery_pct < 15 then 1 end) as devices_low_battery,
        count(case when uptime_pct < 50 then 1 end) as devices_offline
    from device_health
    group by report_date
),

daily_quality as (
    select
        batch_ts::date as report_date,
        round(avg(quality_score), 2) as avg_quality_score,
        sum(quarantined_count) as total_quarantined,
        sum(late_arrival_count) as total_late_arrivals
    from data_quality
    group by 1
),

daily_anomalies as (
    select
        detected_at::date as report_date,
        count(case when severity = 'critical' then 1 end) as critical_alerts,
        count(case when severity = 'warning' then 1 end) as warning_alerts,
        count(*) as total_anomalies
    from anomalies
    group by 1
)

select
    h.report_date,
    h.active_devices,
    h.total_readings,
    coalesce(q.avg_quality_score, 100) as avg_quality_score,
    coalesce(a.critical_alerts, 0) as critical_alerts,
    coalesce(a.warning_alerts, 0) as warning_alerts,
    h.devices_low_battery,
    h.devices_offline,
    h.fleet_uptime_pct,
    h.fleet_avg_battery,
    coalesce(q.total_quarantined, 0) as total_quarantined,
    coalesce(q.total_late_arrivals, 0) as total_late_arrivals,
    coalesce(a.total_anomalies, 0) as total_anomalies

from daily_health h
left join daily_quality q on h.report_date = q.report_date
left join daily_anomalies a on h.report_date = a.report_date
order by h.report_date desc
