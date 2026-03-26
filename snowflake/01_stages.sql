-- =============================================================================
-- Storage Integration & External Stage to S3
-- Run as: ACCOUNTADMIN (storage integrations require it)
-- =============================================================================

USE DATABASE IOT_PIPELINE;
USE SCHEMA RAW;

-- =====================
-- 1. STORAGE INTEGRATION
-- =====================
-- Links Snowflake to your AWS S3 bucket via IAM trust relationship.
-- After creating this, you need to:
--   1. Run: DESC STORAGE INTEGRATION iot_s3_integration;
--   2. Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
--   3. Update your S3 bucket's IAM role trust policy with these values
--
-- See: https://docs.snowflake.com/en/sql-reference/sql/create-storage-integration

CREATE STORAGE INTEGRATION IF NOT EXISTS iot_s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::497162053528:role/iot-fleet-snowflake-role'
    STORAGE_ALLOWED_LOCATIONS = (
        's3://iot-fleet-monitor-data/sensor_readings/',
        's3://iot-fleet-monitor-data/iceberg/'
    );

-- Run this to get the Snowflake IAM user ARN and external ID
-- You'll need these to configure the AWS IAM trust policy
DESC STORAGE INTEGRATION iot_s3_integration;

-- =====================
-- 2. EXTERNAL STAGE
-- =====================
-- Points to the S3 path where Lambda writes sensor data

CREATE STAGE IF NOT EXISTS raw_sensor_stage
    STORAGE_INTEGRATION = iot_s3_integration
    URL = 's3://iot-fleet-monitor-data/sensor_readings/'
    COMMENT = 'S3 stage for raw IoT sensor JSON files (Hive-partitioned)';

-- =====================
-- 3. VERIFY
-- =====================
-- List files in the stage (should see partitioned JSON files after Lambda runs)
-- LIST @raw_sensor_stage;

SHOW STAGES;
