-- =============================================================================
-- Pipeline Health Monitor
-- Detects when Airflow is not processing data (S3 has data but Snowflake is stale)
-- =============================================================================

USE ROLE ACCOUNTADMIN;                                                                                                                                     
GRANT USAGE ON DATABASE IOT_PIPELINE TO ROLE IOT_TRANSFORMER;                                                                                              
GRANT USAGE ON SCHEMA IOT_PIPELINE.MONITORING TO ROLE IOT_TRANSFORMER;                                                                                     
GRANT CREATE VIEW ON SCHEMA IOT_PIPELINE.MONITORING TO ROLE IOT_TRANSFORMER;                                                                               
GRANT CREATE TASK ON SCHEMA IOT_PIPELINE.MONITORING TO ROLE IOT_TRANSFORMER;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE IOT_TRANSFORMER; 

USE ROLE IOT_TRANSFORMER;
USE WAREHOUSE IOT_WH;
USE DATABASE IOT_PIPELINE;

-- View: Pipeline health status — shows at a glance if something is wrong
CREATE OR REPLACE VIEW IOT_PIPELINE.MONITORING.pipeline_health AS
SELECT
    -- Last time data was loaded into Snowflake
    MAX(loaded_at) AS last_snowflake_load,

    -- How many minutes since last load
    DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) AS minutes_since_last_load,

    -- Total rows
    COUNT(*) AS total_raw_rows,

    -- Status determination
    CASE
        WHEN DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) <= 90 THEN 'HEALTHY'
        WHEN DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) <= 180 THEN 'WARNING'
        ELSE 'CRITICAL'
    END AS pipeline_status,

    -- Human-readable message
    CASE
        WHEN DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) <= 90
            THEN 'Pipeline running normally'
        WHEN DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) <= 180
            THEN 'Pipeline delayed — check Airflow. Data may be accumulating in S3.'
        ELSE 'Pipeline DOWN — Airflow has not loaded data for ' ||
             ROUND(DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) / 60.0, 1) ||
             ' hours. S3 data needs recovery load.'
    END AS status_message,

    -- Estimated missed batches (assuming hourly schedule)
    GREATEST(0, ROUND(DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) / 60.0) - 1) AS estimated_missed_batches

FROM IOT_PIPELINE.RAW.sensor_readings;

-- Alert task: runs every 30 min, logs warning if pipeline is stale
CREATE OR REPLACE TASK IOT_PIPELINE.MONITORING.check_pipeline_health
    WAREHOUSE = IOT_WH
    SCHEDULE = '30 MINUTE'
AS
    SELECT
        pipeline_status,
        status_message,
        minutes_since_last_load,
        estimated_missed_batches
    FROM IOT_PIPELINE.MONITORING.pipeline_health
    WHERE pipeline_status != 'HEALTHY';

-- Enable the task
ALTER TASK IOT_PIPELINE.MONITORING.check_pipeline_health RESUME;

-- Quick check query (run anytime):
-- SELECT * FROM IOT_PIPELINE.MONITORING.pipeline_health;


-- Pipeline health (how long since last load)
  SELECT * FROM IOT_PIPELINE.MONITORING.pipeline_health;

  -- How many files are waiting in S3?
  LIST @IOT_PIPELINE.RAW.raw_sensor_stage;

  -- Last loaded data timestamp
  SELECT MAX(loaded_at) AS last_load,
         DATEDIFF(hour, MAX(loaded_at), CURRENT_TIMESTAMP()) AS hours_since_last_load
  FROM IOT_PIPELINE.RAW.sensor_readings;
