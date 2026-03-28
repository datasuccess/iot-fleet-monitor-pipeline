-- =============================================================================
-- Streamlit in Snowflake Setup
-- Creates Git integration + Streamlit apps from the repo
-- =============================================================================

-- =============================================================================
-- Step 1: Run as ACCOUNTADMIN (API integrations require it)
-- =============================================================================
USE ROLE ACCOUNTADMIN;

-- Create API integration for GitHub
CREATE OR REPLACE API INTEGRATION git_api_integration
    API_PROVIDER = git_https_api
    API_ALLOWED_PREFIXES = ('https://github.com/datasuccess/')
    ENABLED = TRUE;

-- Grant usage to our transformer role
GRANT USAGE ON INTEGRATION git_api_integration TO ROLE IOT_TRANSFORMER;

-- =============================================================================
-- Step 2: Switch to IOT_TRANSFORMER for the rest
-- =============================================================================
USE ROLE IOT_TRANSFORMER;
USE WAREHOUSE IOT_WH;
USE DATABASE IOT_PIPELINE;

-- Create Git repository connection
CREATE OR REPLACE GIT REPOSITORY IOT_PIPELINE.RAW.iot_pipeline_repo
    API_INTEGRATION = git_api_integration
    ORIGIN = 'https://github.com/datasuccess/iot-fleet-monitor-pipeline.git';

-- Fetch latest from repo
ALTER GIT REPOSITORY IOT_PIPELINE.RAW.iot_pipeline_repo FETCH;

-- Verify files are visible
-- LIST @IOT_PIPELINE.RAW.iot_pipeline_repo/branches/main/streamlit_snowflake/;

-- Create schema for Streamlit apps
CREATE SCHEMA IF NOT EXISTS IOT_PIPELINE.STREAMLIT;

-- Grant permissions
GRANT USAGE ON SCHEMA IOT_PIPELINE.STREAMLIT TO ROLE IOT_READER;
