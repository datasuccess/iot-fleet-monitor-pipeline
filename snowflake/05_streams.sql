-- =============================================================================
-- Streams — Change Data Capture (CDC) on raw tables
-- =============================================================================
-- A Stream tracks changes (inserts, updates, deletes) on a table.
-- It acts like a bookmark — each time you consume the stream, it advances.
--
-- Why use Streams?
--   - Know exactly which rows are NEW since last processing
--   - Enables incremental processing without timestamps
--   - Works with Snowflake Tasks for autonomous pipelines
--
-- How it works:
--   1. Data is loaded into raw.sensor_readings
--   2. Stream captures the new rows
--   3. A downstream process (Task or dbt) reads the stream
--   4. After reading, the stream "advances" — those rows won't appear again
--
-- Stream columns added automatically:
--   METADATA$ACTION     — 'INSERT', 'DELETE'
--   METADATA$ISUPDATE   — TRUE if this is the UPDATE part of an update
--   METADATA$ROW_ID     — Unique row identifier
-- =============================================================================

USE DATABASE IOT_PIPELINE;
USE SCHEMA RAW;

-- =====================
-- 1. STREAM ON SENSOR READINGS
-- =====================
CREATE STREAM IF NOT EXISTS sensor_readings_stream
    ON TABLE sensor_readings
    APPEND_ONLY = TRUE      -- Only track INSERTs (we don't update/delete raw data)
    COMMENT = 'CDC stream on raw sensor readings - tracks new inserts only';

-- =====================
-- 2. VERIFY
-- =====================
SHOW STREAMS;

-- Check if stream has new data:
-- SELECT SYSTEM$STREAM_HAS_DATA('sensor_readings_stream');

-- Preview stream contents (doesn't consume):
-- SELECT * FROM sensor_readings_stream LIMIT 10;
