-- =============================================================================
-- Snowflake Tasks — Autonomous freshness monitoring
-- =============================================================================
-- Tasks are Snowflake's built-in scheduler. They run SQL on a schedule
-- or when triggered by a stream having new data.
--
-- We use a Task to automatically monitor data freshness:
--   "Has new data arrived in the last N minutes?"
--
-- This runs independently of Airflow — it's a safety net.
-- If Airflow goes down, Snowflake still monitors freshness.
-- =============================================================================

USE DATABASE IOT_PIPELINE;
USE SCHEMA MONITORING;
USE WAREHOUSE IOT_WH;

-- =====================
-- 1. FRESHNESS LOG TABLE
-- =====================
CREATE TABLE IF NOT EXISTS freshness_log (
    check_id        VARCHAR        DEFAULT UUID_STRING(),
    check_ts        TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
    table_name      VARCHAR,
    latest_loaded_at TIMESTAMP_NTZ,
    minutes_since_load FLOAT,
    is_fresh        BOOLEAN        COMMENT 'TRUE if data arrived within threshold',
    threshold_minutes INTEGER      DEFAULT 60,
    COMMENT = 'Automated freshness check results'
);

-- =====================
-- 2. FRESHNESS CHECK TASK
-- =====================
-- Runs every 30 minutes, checks if raw.sensor_readings has recent data

CREATE TASK IF NOT EXISTS check_raw_freshness
    WAREHOUSE = IOT_WH
    SCHEDULE = 'USING CRON 0,30 * * * * UTC'  -- Every 30 minutes
    COMMENT = 'Check if raw sensor data is arriving on time'
AS
    INSERT INTO MONITORING.freshness_log (table_name, latest_loaded_at, minutes_since_load, is_fresh, threshold_minutes)
    SELECT
        'RAW.SENSOR_READINGS',
        MAX(loaded_at),
        TIMESTAMPDIFF(MINUTE, MAX(loaded_at), CURRENT_TIMESTAMP()),
        TIMESTAMPDIFF(MINUTE, MAX(loaded_at), CURRENT_TIMESTAMP()) <= 60,
        60
    FROM IOT_PIPELINE.RAW.sensor_readings;

-- =====================
-- 3. TASK MANAGEMENT
-- =====================
-- Tasks are created in SUSPENDED state. Resume to start:
--   ALTER TASK check_raw_freshness RESUME;
--
-- Suspend:
--   ALTER TASK check_raw_freshness SUSPEND;
--
-- Check task history:
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
--   WHERE NAME = 'CHECK_RAW_FRESHNESS'
--   ORDER BY SCHEDULED_TIME DESC
--   LIMIT 10;

-- =====================
-- 4. VERIFY
-- =====================
SHOW TASKS;
