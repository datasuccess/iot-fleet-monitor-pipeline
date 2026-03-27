-- =============================================================================
-- IOT FLEET MONITOR — SNOWSIGHT QUALITY DASHBOARD
-- =============================================================================
-- Each query below is designed to be run independently as a Snowsight tile.
-- Copy-paste individual blocks into Snowsight worksheets or dashboard tiles.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. DATA QUALITY TREND (last 7 days)
-- ---------------------------------------------------------------------------
-- Line chart: quality_score over time to spot degradation patterns.

SELECT
    measured_at::DATE AS quality_date,
    ROUND(AVG(quality_score), 2) AS avg_quality_score,
    MIN(quality_score) AS min_quality_score,
    MAX(quality_score) AS max_quality_score
FROM IOT_PIPELINE.MARTS.FCT_DATA_QUALITY
WHERE measured_at >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY quality_date
ORDER BY quality_date;


-- ---------------------------------------------------------------------------
-- 2. ANOMALY SUMMARY (last 24 hours)
-- ---------------------------------------------------------------------------
-- Grouped bar chart: anomaly counts broken down by severity and sensor type.

SELECT
    severity,
    sensor_type,
    COUNT(*) AS anomaly_count
FROM IOT_PIPELINE.MARTS.FCT_ANOMALIES
WHERE detected_at >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
GROUP BY severity, sensor_type
ORDER BY anomaly_count DESC;


-- ---------------------------------------------------------------------------
-- 3. FLEET HEALTH (latest day)
-- ---------------------------------------------------------------------------
-- Donut / pie chart: how many devices in each health status bucket.

SELECT
    health_status,
    COUNT(DISTINCT device_id) AS device_count
FROM IOT_PIPELINE.MARTS.FCT_DEVICE_HEALTH
WHERE measured_at::DATE = CURRENT_DATE()
GROUP BY health_status
ORDER BY device_count DESC;


-- ---------------------------------------------------------------------------
-- 4. DEVICE BATTERY HEATMAP (last 3 days)
-- ---------------------------------------------------------------------------
-- Heatmap or table: identify devices with critically low battery.

SELECT
    device_id,
    ROUND(AVG(avg_battery_pct), 1) AS avg_battery_pct,
    MIN(min_battery_pct) AS min_battery_pct
FROM IOT_PIPELINE.MARTS.FCT_DEVICE_HEALTH
WHERE measured_at >= DATEADD('day', -3, CURRENT_TIMESTAMP())
GROUP BY device_id
ORDER BY avg_battery_pct ASC;


-- ---------------------------------------------------------------------------
-- 5. HOURLY READING VOLUME (last 24 hours)
-- ---------------------------------------------------------------------------
-- Bar chart: reading throughput per hour to detect ingestion gaps.

SELECT
    DATE_TRUNC('hour', reading_hour) AS hour_bucket,
    SUM(reading_count) AS total_readings
FROM IOT_PIPELINE.MARTS.FCT_HOURLY_READINGS
WHERE reading_hour >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
GROUP BY hour_bucket
ORDER BY hour_bucket;


-- ---------------------------------------------------------------------------
-- 6. FLEET OVERVIEW KPIs (latest snapshot)
-- ---------------------------------------------------------------------------
-- Scorecard tiles: headline numbers for the entire fleet.

SELECT *
FROM IOT_PIPELINE.MARTS.RPT_FLEET_OVERVIEW
ORDER BY generated_at DESC
LIMIT 1;


-- ---------------------------------------------------------------------------
-- 7. QUARANTINE RATE (last 7 days)
-- ---------------------------------------------------------------------------
-- Line chart: percentage of records quarantined each day.

SELECT
    measured_at::DATE AS quality_date,
    SUM(quarantined_count) AS total_quarantined,
    SUM(total_records) AS total_records,
    ROUND(
        100.0 * SUM(quarantined_count) / NULLIF(SUM(total_records), 0),
        2
    ) AS quarantine_rate_pct
FROM IOT_PIPELINE.MARTS.FCT_DATA_QUALITY
WHERE measured_at >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY quality_date
ORDER BY quality_date;


-- ---------------------------------------------------------------------------
-- 8. TOP ANOMALY DEVICES (last 7 days)
-- ---------------------------------------------------------------------------
-- Horizontal bar chart: the 10 noisiest devices by anomaly volume.

SELECT
    device_id,
    COUNT(*) AS anomaly_count,
    COUNT(DISTINCT sensor_type) AS affected_sensors,
    MAX(detected_at) AS latest_anomaly
FROM IOT_PIPELINE.MARTS.FCT_ANOMALIES
WHERE detected_at >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY device_id
ORDER BY anomaly_count DESC
LIMIT 10;
