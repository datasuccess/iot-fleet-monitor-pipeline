-- =============================================================================
-- Integration Tests for Snowflake Setup
-- Run these after executing 00-07 setup scripts and loading some data
-- Each test has an EXPECTED result — verify manually
-- =============================================================================

USE DATABASE IOT_PIPELINE;
USE WAREHOUSE IOT_WH;

-- =====================
-- TEST 1: All schemas exist
-- EXPECTED: RAW, STAGING, INTERMEDIATE, MARTS, MONITORING (+ default schemas)
-- =====================
SELECT SCHEMA_NAME
FROM INFORMATION_SCHEMA.SCHEMATA
WHERE CATALOG_NAME = 'IOT_PIPELINE'
ORDER BY SCHEMA_NAME;

-- =====================
-- TEST 2: All roles exist
-- EXPECTED: IOT_LOADER, IOT_TRANSFORMER, IOT_READER
-- =====================
SHOW ROLES LIKE 'IOT_%';

-- =====================
-- TEST 3: Raw table exists with correct columns
-- EXPECTED: raw_data (VARIANT), loaded_at (TIMESTAMP_NTZ), source_file (VARCHAR)
-- =====================
DESC TABLE RAW.sensor_readings;

-- =====================
-- TEST 4: Can list files in S3 stage
-- EXPECTED: List of JSON files (after Lambda has run)
-- If empty, Lambda hasn't written data yet — run Lambda first
-- =====================
LIST @RAW.raw_sensor_stage;

-- =====================
-- TEST 5: COPY INTO works — load data from S3
-- EXPECTED: rows_loaded > 0
-- =====================
COPY INTO RAW.sensor_readings (raw_data, loaded_at, source_file)
FROM (
    SELECT
        $1,
        CURRENT_TIMESTAMP(),
        METADATA$FILENAME
    FROM @RAW.raw_sensor_stage
)
FILE_FORMAT = RAW.json_sensor_format
PATTERN = '.*\.json'
ON_ERROR = 'CONTINUE';

-- =====================
-- TEST 6: Data loaded — row count check
-- EXPECTED: > 0 rows (50 per batch × number of Lambda invocations)
-- =====================
SELECT COUNT(*) AS total_rows FROM RAW.sensor_readings;

-- =====================
-- TEST 7: VARIANT fields are accessible
-- EXPECTED: device_id, temperature, humidity values readable
-- =====================
SELECT
    raw_data:reading_id::VARCHAR    AS reading_id,
    raw_data:device_id::VARCHAR     AS device_id,
    raw_data:reading_ts::TIMESTAMP  AS reading_ts,
    raw_data:temperature::FLOAT     AS temperature,
    raw_data:humidity::FLOAT        AS humidity,
    raw_data:pressure::FLOAT        AS pressure,
    raw_data:battery_pct::FLOAT     AS battery_pct,
    raw_data:latitude::FLOAT        AS latitude,
    raw_data:longitude::FLOAT       AS longitude,
    raw_data:firmware_version::VARCHAR AS firmware_version,
    source_file,
    loaded_at
FROM RAW.sensor_readings
LIMIT 10;

-- =====================
-- TEST 8: All 50 devices present in data
-- EXPECTED: 50 distinct device_ids (DEV_001 through DEV_050)
-- =====================
SELECT
    COUNT(DISTINCT raw_data:device_id::VARCHAR) AS distinct_devices
FROM RAW.sensor_readings;

-- =====================
-- TEST 9: Stream detects new data
-- EXPECTED: SYSTEM$STREAM_HAS_DATA returns TRUE if data was loaded after stream creation
-- =====================
SELECT SYSTEM$STREAM_HAS_DATA('RAW.sensor_readings_stream') AS stream_has_data;

-- =====================
-- TEST 10: Freshness monitoring table exists
-- EXPECTED: Table exists, 0 rows initially (populated by task)
-- =====================
SELECT COUNT(*) AS freshness_checks FROM MONITORING.freshness_log;

-- =====================
-- TEST 11: Source file partitioning is correct
-- EXPECTED: Paths follow year=YYYY/month=MM/day=DD/hour=HH/ pattern
-- =====================
SELECT DISTINCT source_file
FROM RAW.sensor_readings
ORDER BY source_file
LIMIT 10;

-- =====================
-- TEST 12: No null reading_ids in raw data (before error injection)
-- EXPECTED: With 'none' profile, 0 nulls. With other profiles, some nulls possible.
-- =====================
SELECT
    COUNT(*) AS total,
    COUNT(raw_data:reading_id::VARCHAR) AS non_null_ids,
    COUNT(*) - COUNT(raw_data:reading_id::VARCHAR) AS null_ids
FROM RAW.sensor_readings;
