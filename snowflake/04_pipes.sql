-- =============================================================================
-- Snowpipe — Auto-ingest from S3
-- =============================================================================
-- Snowpipe automatically loads new files as they arrive in S3.
-- It uses S3 event notifications (SQS) to trigger loading.
--
-- How it works:
--   1. Lambda writes a JSON file to S3
--   2. S3 sends an event notification to an SQS queue
--   3. Snowpipe detects the event and runs COPY INTO
--   4. Data appears in raw.sensor_readings within ~1 minute
--
-- This is OPTIONAL — our Airflow DAG also does COPY INTO explicitly.
-- Snowpipe is useful for near-real-time ingestion without scheduling.
--
-- Setup steps after creating the pipe:
--   1. Run: SHOW PIPES;
--   2. Copy the notification_channel (SQS queue ARN)
--   3. Configure S3 bucket event notifications to send to that SQS queue
-- =============================================================================

USE DATABASE IOT_PIPELINE;
USE SCHEMA RAW;

-- =====================
-- 1. SNOWPIPE DEFINITION
-- =====================
CREATE PIPE IF NOT EXISTS sensor_readings_pipe
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-ingest sensor readings from S3 as files arrive'
AS
COPY INTO sensor_readings (raw_data, loaded_at, source_file)
FROM (
    SELECT
        $1,
        CURRENT_TIMESTAMP(),
        METADATA$FILENAME
    FROM @raw_sensor_stage
)
FILE_FORMAT = json_sensor_format
ON_ERROR = 'CONTINUE';

-- =====================
-- 2. VERIFY & GET SQS QUEUE ARN
-- =====================
SHOW PIPES;

-- The notification_channel column contains the SQS ARN.
-- Use it to configure S3 event notifications:
--   aws s3api put-bucket-notification-configuration ...

-- =====================
-- 3. PIPE MANAGEMENT COMMANDS
-- =====================
-- Check pipe status:
--   SELECT SYSTEM$PIPE_STATUS('sensor_readings_pipe');
--
-- Pause pipe:
--   ALTER PIPE sensor_readings_pipe SET PIPE_EXECUTION_PAUSED = TRUE;
--
-- Resume pipe:
--   ALTER PIPE sensor_readings_pipe SET PIPE_EXECUTION_PAUSED = FALSE;
--
-- Force refresh (load files that were missed):
--   ALTER PIPE sensor_readings_pipe REFRESH;


-- DESC STORAGE INTEGRATION iot_s3_integration;

-- LIST @RAW.raw_sensor_stage;