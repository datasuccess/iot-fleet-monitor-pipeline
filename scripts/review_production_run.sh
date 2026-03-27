#!/bin/bash
# =============================================================================
# Review script — Run after 5-day production run
# Generates SQL queries to analyze pipeline behavior across all 5 days
# =============================================================================

cat << 'QUERIES'
-- =============================================================================
-- POST-PRODUCTION RUN REVIEW QUERIES
-- Run these in Snowflake after 5 days of pipeline operation
-- =============================================================================

-- 1. DAILY QUALITY TREND
-- Shows how quality_score changed across error profiles
SELECT
    batch_ts::date AS run_date,
    COUNT(*) AS batches,
    ROUND(AVG(quality_score), 2) AS avg_quality,
    ROUND(MIN(quality_score), 2) AS min_quality,
    SUM(null_count) AS total_nulls,
    SUM(duplicate_count) AS total_dupes,
    SUM(quarantined_count) AS total_quarantined
FROM IOT_PIPELINE.MARTS.fct_data_quality
GROUP BY 1
ORDER BY 1;

-- 2. ANOMALY VOLUME BY DAY AND SEVERITY
-- Should spike on Day 3-4 (high/chaos) and recover on Day 5
SELECT
    detected_at::date AS run_date,
    severity,
    sensor_type,
    COUNT(*) AS anomaly_count
FROM IOT_PIPELINE.MARTS.fct_anomalies
GROUP BY 1, 2, 3
ORDER BY 1, 2;

-- 3. DEVICE HEALTH DISTRIBUTION
-- How many devices were critical/warning/healthy each day
SELECT
    report_date,
    health_status,
    COUNT(*) AS device_count,
    ROUND(AVG(uptime_pct), 2) AS avg_uptime,
    ROUND(AVG(avg_battery_pct), 2) AS avg_battery
FROM IOT_PIPELINE.MARTS.fct_device_health
GROUP BY 1, 2
ORDER BY 1, 2;

-- 4. FLEET OVERVIEW — THE EXECUTIVE VIEW
SELECT *
FROM IOT_PIPELINE.MARTS.rpt_fleet_overview
ORDER BY report_date;

-- 5. INCREMENTAL MODEL BEHAVIOR
-- Verify row counts grew incrementally each day
SELECT
    reading_hour::date AS run_date,
    COUNT(*) AS hourly_buckets,
    SUM(reading_count) AS total_readings,
    SUM(anomaly_count) AS total_anomalies
FROM IOT_PIPELINE.MARTS.fct_hourly_readings
GROUP BY 1
ORDER BY 1;

-- 6. SCD TYPE 2 HISTORY (if any device metadata changed)
SELECT *
FROM IOT_PIPELINE.SNAPSHOTS.snap_device_metadata
WHERE dbt_valid_to IS NOT NULL
ORDER BY device_id, dbt_valid_from;

-- 7. QUARANTINE ANALYSIS
-- What types of errors were caught and when
SELECT
    loaded_at::date AS run_date,
    rejection_reasons,
    COUNT(*) AS record_count
FROM IOT_PIPELINE.INTERMEDIATE.int_quarantined_readings
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- 8. LATE ARRIVALS
SELECT
    loaded_at::date AS run_date,
    COUNT(*) AS late_records,
    ROUND(AVG(arrival_delay_minutes), 1) AS avg_delay_minutes,
    MAX(arrival_delay_minutes) AS max_delay_minutes
FROM IOT_PIPELINE.INTERMEDIATE.int_late_arriving_readings
GROUP BY 1
ORDER BY 1;

-- 9. DEDUP EFFECTIVENESS
-- Compare raw vs deduped counts per day
SELECT
    s.loaded_at::date AS run_date,
    COUNT(DISTINCT s.reading_id) AS raw_count,
    COUNT(DISTINCT d.reading_id) AS deduped_count,
    raw_count - deduped_count AS dupes_removed
FROM IOT_PIPELINE.STAGING.stg_sensor_readings s
LEFT JOIN IOT_PIPELINE.INTERMEDIATE.int_readings_deduped d
    ON s.reading_id = d.reading_id
GROUP BY 1
ORDER BY 1;

QUERIES

echo ""
echo "Copy the queries above and run them in Snowflake Snowsight."
echo "These cover all aspects of the 5-day production run."
