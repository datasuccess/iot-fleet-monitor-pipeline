-- =============================================================================
-- Apache Iceberg Table Setup for Mart Layer
-- =============================================================================
-- Snowflake-managed Iceberg tables store data as Parquet files on S3.
-- Snowflake manages the Iceberg metadata (manifests, snapshots).
--
-- Benefits:
--   - Open format: queryable by Spark, Trino, Athena, DuckDB without Snowflake
--   - Time travel: query historical snapshots via Iceberg metadata
--   - Schema evolution: add columns without rewriting data
--   - Efficient pruning: column min/max statistics in Iceberg metadata
--
-- Architecture:
--   dbt creates mart models → Snowflake writes Parquet to S3 → Iceberg metadata on S3
--   External engines read S3 directly using Iceberg catalog
--
-- Run as: ACCOUNTADMIN
-- =============================================================================

USE DATABASE IOT_PIPELINE;

-- =====================
-- 1. EXTERNAL VOLUME
-- =====================
-- Points to the S3 location where Iceberg data (Parquet + metadata) will be stored.
-- This is different from the raw stage — raw stores JSON, this stores Parquet.

CREATE EXTERNAL VOLUME IF NOT EXISTS iot_iceberg_volume
    STORAGE_LOCATIONS = (
        (
            NAME = 'iot-iceberg-s3'
            STORAGE_BASE_URL = 's3://iot-fleet-monitor-data/iceberg/'
            STORAGE_PROVIDER = 'S3'
            STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/iot-fleet-snowflake-role'
        )
    );

-- After creating, run:
--   DESC EXTERNAL VOLUME iot_iceberg_volume;
-- Copy the IAM user ARN and update the AWS trust policy (same as storage integration).

-- =====================
-- 2. ICEBERG TABLE EXAMPLES (Mart Layer)
-- =====================
-- These tables will be created by dbt in Phase 5.
-- Below are examples showing the DDL pattern for reference.
--
-- In dbt, mart models will use post-hooks or custom materializations
-- to create Iceberg tables instead of regular Snowflake tables.

-- Example: Fact Hourly Readings as Iceberg table
-- CREATE ICEBERG TABLE IF NOT EXISTS MARTS.fct_hourly_readings (
--     hourly_reading_id   VARCHAR,
--     device_id           VARCHAR,
--     reading_hour        TIMESTAMP_NTZ,
--     avg_temperature     FLOAT,
--     min_temperature     FLOAT,
--     max_temperature     FLOAT,
--     stddev_temperature  FLOAT,
--     avg_humidity        FLOAT,
--     avg_pressure        FLOAT,
--     avg_battery_pct     FLOAT,
--     reading_count       INTEGER,
--     anomaly_count       INTEGER
-- )
--     CATALOG = 'SNOWFLAKE'
--     EXTERNAL_VOLUME = 'iot_iceberg_volume'
--     BASE_LOCATION = 'marts/fct_hourly_readings/';

-- =====================
-- 3. ICEBERG METADATA QUERIES
-- =====================
-- After tables are populated, you can query Iceberg metadata:
--
-- View table snapshots (time travel):
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS('MARTS.fct_hourly_readings'));
--
-- View data files (Parquet files on S3):
--   SELECT * FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_FILES('MARTS.fct_hourly_readings'));
--
-- Query at a previous snapshot:
--   SELECT * FROM MARTS.fct_hourly_readings AT(TIMESTAMP => '2026-03-25 12:00:00'::TIMESTAMP);

-- =====================
-- 4. VERIFY
-- =====================
DESC EXTERNAL VOLUME iot_iceberg_volume;
