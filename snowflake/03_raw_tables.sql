-- =============================================================================
-- Raw Tables — VARIANT columns for semi-structured JSON
-- =============================================================================

USE DATABASE IOT_PIPELINE;
USE SCHEMA RAW;
USE WAREHOUSE IOT_WH;

-- =====================
-- 1. SENSOR READINGS (main table)
-- =====================
-- Stores the entire JSON payload as a single VARIANT column.
-- This is different from the main branch which uses typed columns.
--
-- Why VARIANT?
--   - Schema-on-read: no need to define columns upfront
--   - Handles schema drift naturally (new/missing fields don't break loading)
--   - Preserves the original payload for debugging
--   - Parsing happens in dbt staging layer with TRY_CAST

CREATE TABLE IF NOT EXISTS sensor_readings (
    raw_data        VARIANT        COMMENT 'Entire JSON reading as semi-structured data',
    loaded_at       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP() COMMENT 'When this row was loaded',
    source_file     VARCHAR        COMMENT 'S3 file path this reading came from'
);

-- =====================
-- 2. LOAD AUDIT LOG
-- =====================
-- Tracks every COPY INTO operation for observability

CREATE TABLE IF NOT EXISTS load_audit_log (
    load_id         VARCHAR        DEFAULT UUID_STRING() COMMENT 'Unique load identifier',
    source_file     VARCHAR        COMMENT 'S3 file path loaded',
    rows_loaded     INTEGER        COMMENT 'Number of rows loaded',
    rows_parsed     INTEGER        COMMENT 'Number of rows parsed from file',
    errors_seen     INTEGER        DEFAULT 0 COMMENT 'Number of parse errors',
    load_status     VARCHAR        COMMENT 'SUCCESS, PARTIAL, FAILED',
    loaded_at       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
    error_details   VARIANT        COMMENT 'Error details if any'
);

-- =====================
-- 3. MANUAL COPY INTO (for testing)
-- =====================
-- Use this to test loading before Airflow is wired up.
-- Uncomment and run after Lambda has written data to S3:
--
-- COPY INTO sensor_readings (raw_data, loaded_at, source_file)
-- FROM (
--     SELECT
--         $1,
--         CURRENT_TIMESTAMP(),
--         METADATA$FILENAME
--     FROM @raw_sensor_stage
-- )
-- FILE_FORMAT = json_sensor_format
-- PATTERN = '.*\.json'
-- ON_ERROR = 'CONTINUE';

-- =====================
-- 4. VERIFY
-- =====================
SHOW TABLES IN SCHEMA RAW;
DESC TABLE sensor_readings;
