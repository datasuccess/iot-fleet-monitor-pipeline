-- =============================================================================
-- Streamlit in Snowflake Setup
-- Creates Git integration + Streamlit apps from the repo
-- =============================================================================

USE ROLE IOT_TRANSFORMER;
USE WAREHOUSE IOT_WH;
USE DATABASE IOT_PIPELINE;

-- 1. Create API integration for GitHub
CREATE OR REPLACE API INTEGRATION git_api_integration
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/datasuccess/')
    ENABLED = TRUE;

-- 2. Create Git repository connection
CREATE OR REPLACE GIT REPOSITORY IOT_PIPELINE.RAW.iot_pipeline_repo
    API_INTEGRATION = git_api_integration
    ORIGIN = 'https://github.com/datasuccess/iot-fleet-monitor-pipeline.git';

-- 3. Fetch latest from repo
ALTER GIT REPOSITORY IOT_PIPELINE.RAW.iot_pipeline_repo FETCH;

-- 4. Verify files are visible
-- LIST @IOT_PIPELINE.RAW.iot_pipeline_repo/branches/main/streamlit/;

-- 5. Create schema for Streamlit apps
CREATE SCHEMA IF NOT EXISTS IOT_PIPELINE.STREAMLIT;

-- 6. Grant permissions
GRANT USAGE ON SCHEMA IOT_PIPELINE.STREAMLIT TO ROLE IOT_READER;
