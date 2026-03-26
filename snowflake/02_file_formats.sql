-- =============================================================================
-- File Formats for JSON ingestion
-- =============================================================================

USE DATABASE IOT_PIPELINE;
USE SCHEMA RAW;

-- =====================
-- JSON File Format
-- =====================
-- STRIP_OUTER_ARRAY = TRUE because Lambda writes a JSON array of readings:
--   [{"reading_id": "...", ...}, {"reading_id": "...", ...}]
-- Without this flag, the entire array would load as one VARIANT row.
-- With it, each array element becomes its own row.

CREATE FILE FORMAT IF NOT EXISTS json_sensor_format
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    IGNORE_UTF8_ERRORS = TRUE          -- Handle any encoding issues gracefully
    ENABLE_OCTAL = FALSE
    ALLOW_DUPLICATE = TRUE             -- Preserve duplicates (we handle dedup in dbt)
    STRIP_NULL_VALUES = FALSE          -- Keep nulls (we track them for data quality)
    COMMENT = 'JSON format for sensor readings - strips outer array, preserves nulls';

-- =====================
-- VERIFY
-- =====================
SHOW FILE FORMATS;
DESC FILE FORMAT json_sensor_format;
