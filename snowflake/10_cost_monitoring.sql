-- =============================================================================
-- Snowflake Cost Monitoring & Optimization
-- Run as ACCOUNTADMIN (required for ACCOUNT_USAGE views)
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- =============================================================================
-- 1. CREDIT USAGE BY WAREHOUSE
-- =============================================================================
-- Warehouses are the #1 cost driver in Snowflake. Every time a warehouse
-- "wakes up" to run a query, you pay for at least 60 seconds of compute
-- (even if the query takes 1 second). This is called the "minimum billing" rule.
--
-- credits_used_compute = actual query processing
-- credits_used_cloud_services = metadata operations (usually free if < 10% of compute)
--
-- On a trial account: 1 credit ≈ $2-4 depending on edition.
-- XS warehouse = 1 credit/hour. If it runs for 60 seconds, you pay 1/60 of a credit.

SELECT
    warehouse_name,
    SUM(credits_used) AS total_credits,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_used_cloud_services) AS cloud_credits,
    COUNT(*) AS num_executions
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;


-- =============================================================================
-- 2. CREDIT USAGE BY DAY
-- =============================================================================
-- See which days burned the most credits. Useful for spotting:
--   - Days you left a warehouse running
--   - Days with heavy dbt runs or chaos error profiles
--   - Unexpected spikes from scheduled tasks

SELECT
    DATE_TRUNC('day', start_time) AS usage_date,
    warehouse_name,
    SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD(day, -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;


-- =============================================================================
-- 3. MOST EXPENSIVE QUERIES
-- =============================================================================
-- Find the slowest queries — longer runtime = more credits burned.
-- Common offenders:
--   - Full table scans on large tables (missing WHERE clause)
--   - dbt models doing FULL REFRESH instead of incremental
--   - Streamlit dashboards running expensive queries on every page load
--   - COPY INTO scanning thousands of files

SELECT
    query_id,
    LEFT(query_text, 100) AS query_preview,
    warehouse_name,
    execution_status,
    ROUND(total_elapsed_time / 1000, 1) AS seconds,
    ROUND(credits_used_cloud_services, 4) AS cloud_credits,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 20;


-- =============================================================================
-- 4. QUERY COUNT BY SOURCE (what's generating queries?)
-- =============================================================================
-- Groups queries by type so you can see if most cost comes from
-- dbt, Airflow COPY INTO, Streamlit dashboards, or scheduled tasks.
--
-- query_tag is set by connectors (dbt sets it automatically).

SELECT
    DATE_TRUNC('day', start_time) AS query_date,
    CASE
        WHEN query_tag LIKE '%dbt%' THEN 'dbt'
        WHEN query_text ILIKE '%COPY INTO%' THEN 'COPY INTO (Airflow)'
        WHEN query_text ILIKE '%TASK%' THEN 'Scheduled Task'
        WHEN query_text ILIKE '%streamlit%' OR user_name = 'STREAMLIT' THEN 'Streamlit'
        ELSE 'Other'
    END AS source,
    COUNT(*) AS query_count,
    ROUND(SUM(total_elapsed_time) / 1000, 1) AS total_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1 DESC, 4 DESC;


-- =============================================================================
-- 5. SCHEDULED TASKS (silent credit burners)
-- =============================================================================
-- Tasks run on a schedule and wake up the warehouse each time.
-- Our check_pipeline_health runs every 30 min = 48 warehouse wake-ups per day.
-- Each wake-up costs minimum 1/60 of a credit (60-second minimum billing).
-- That's ~0.8 credits/day just for a simple SELECT.
--
-- On a trial account, this adds up fast.

SHOW TASKS IN DATABASE IOT_PIPELINE;

-- Check task run history (how many times did they actually run?)
SELECT
    name,
    state,
    scheduled_time,
    completed_time,
    DATEDIFF(second, scheduled_time, completed_time) AS runtime_seconds
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(day, -7, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 50
))
ORDER BY scheduled_time DESC;


-- =============================================================================
-- 6. WAREHOUSE SETTINGS (auto-suspend is critical)
-- =============================================================================
-- AUTO_SUSPEND = seconds of inactivity before warehouse shuts down.
--   - Default is 600 (10 minutes) — way too long for dev/trial
--   - Set to 60 (1 minute) to minimize idle billing
--
-- AUTO_RESUME = warehouse wakes up automatically when a query arrives.
--   - Always keep this TRUE, otherwise queries will fail.
--
-- WAREHOUSE_SIZE:
--   - XSMALL = 1 credit/hour (sufficient for this project)
--   - SMALL  = 2 credits/hour
--   - MEDIUM = 4 credits/hour
--   - Each size up doubles the cost

SHOW WAREHOUSES;


-- =============================================================================
-- 7. SNOWPIPE STATUS (if enabled)
-- =============================================================================
-- Snowpipe runs continuously and charges ~0.06 credits per 1000 notifications.
-- If you set up Snowpipe (04_pipes.sql) but aren't using it, it's burning money.
-- Check if any pipes are running:

SHOW PIPES IN DATABASE IOT_PIPELINE;


-- =============================================================================
-- 8. STORAGE COSTS
-- =============================================================================
-- Storage is cheap (~$23/TB/month for on-demand) but check anyway.
-- Time Travel and Fail-safe keep deleted/changed data for up to 90 days.

SELECT
    TABLE_CATALOG AS database_name,
    TABLE_SCHEMA AS schema_name,
    TABLE_NAME,
    ROUND(BYTES / (1024*1024), 2) AS size_mb,
    ROUND(TIME_TRAVEL_BYTES / (1024*1024), 2) AS time_travel_mb,
    ROUND(FAILSAFE_BYTES / (1024*1024), 2) AS failsafe_mb,
    ROW_COUNT
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG = 'IOT_PIPELINE'
    AND DELETED IS NULL
ORDER BY BYTES DESC;


-- =============================================================================
-- COST CUTTING: Run these to minimize spend immediately
-- =============================================================================

-- 1. Suspend all scheduled tasks (biggest silent cost)
USE ROLE IOT_TRANSFORMER;
ALTER TASK IOT_PIPELINE.MONITORING.check_pipeline_health SUSPEND;

-- 2. Set warehouse to auto-suspend after 60 seconds (not 600)
USE ROLE ACCOUNTADMIN;
ALTER WAREHOUSE IOT_WH SET AUTO_SUSPEND = 60;

-- 3. Make sure warehouse is XSMALL
ALTER WAREHOUSE IOT_WH SET WAREHOUSE_SIZE = 'XSMALL';

-- 4. Suspend warehouse right now (don't wait for auto-suspend)
ALTER WAREHOUSE IOT_WH SUSPEND;

-- 5. Suspend any Snowpipes (if they exist and are running)
-- ALTER PIPE IOT_PIPELINE.RAW.sensor_readings_pipe SET PIPE_EXECUTION_PAUSED = TRUE;


-- =============================================================================
-- COST CHEAT SHEET
-- =============================================================================
--
-- What costs money in Snowflake:
--
-- 1. COMPUTE (warehouses)         ~85% of most bills
--    - You pay per-second, minimum 60 seconds per wake-up
--    - XS = 1 credit/hr, S = 2, M = 4, L = 8, XL = 16
--    - 1 credit ≈ $2-4 depending on your edition
--    - BIGGEST WASTE: warehouse sitting idle with high AUTO_SUSPEND
--
-- 2. CLOUD SERVICES               ~5-10% (usually free)
--    - Metadata operations, query parsing, login
--    - Free if < 10% of your compute credits
--    - Only charged for the excess above 10%
--
-- 3. STORAGE                       ~5% of most bills
--    - $23/TB/month (on-demand) or $40/TB/month (capacity)
--    - Our dataset is tiny (< 100MB), so this is basically free
--    - Time Travel (default 1 day) and Fail-safe (7 days) add ~8x overhead
--
-- 4. SERVERLESS FEATURES           variable
--    - Snowpipe: ~0.06 credits per 1000 file notifications
--    - Tasks (serverless mode): auto-scales, hard to predict cost
--    - Our tasks use the warehouse (not serverless), so cost = warehouse wake-up
--
-- Trial account: 400 credits total. At 1 credit = $3.50 average, that's ~$1,400.
-- A single XS warehouse running 24/7 would burn 24 credits/day = gone in 16 days.
-- With AUTO_SUSPEND = 60, you only pay when queries actually run.
--
-- =============================================================================
