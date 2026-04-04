# Phase 2: Snowflake Setup — Code Explained

## 1. VARIANT Columns (03_raw_tables.sql)

```sql
CREATE TABLE sensor_readings (
    raw_data    VARIANT,
    loaded_at   TIMESTAMP_NTZ,
    source_file VARCHAR
);
```

**VARIANT** is Snowflake's semi-structured data type. It stores the entire JSON payload as-is — no column definitions needed.

**Why not typed columns?**
- **Schema drift**: If Lambda adds a new field (e.g., `signal_strength`), typed columns would break the load. VARIANT handles it automatically.
- **Preserve original**: Raw data stays untouched for debugging. If dbt parsing has a bug, you can always go back to the VARIANT.
- **Schema-on-read**: We define the structure later in dbt staging, not at ingestion time.

To read fields from VARIANT:
```sql
SELECT
    raw_data:device_id::VARCHAR AS device_id,
    raw_data:temperature::FLOAT AS temperature
FROM sensor_readings;
```

The `:` operator navigates JSON paths. `::FLOAT` casts the value.

---

## 2. Storage Integration (01_stages.sql)

```sql
CREATE STORAGE INTEGRATION iot_s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::...:role/...'
    STORAGE_ALLOWED_LOCATIONS = ('s3://iot-fleet-monitor-data/...');
```

This creates a **trust relationship** between Snowflake and your S3 bucket:
1. Snowflake creates an IAM user in its own AWS account
2. You update your IAM role to trust that Snowflake user
3. Now Snowflake can read/write your S3 bucket securely — no access keys needed

This is more secure than passing AWS credentials directly.

---

## 3. STRIP_OUTER_ARRAY (02_file_formats.sql)

```sql
CREATE FILE FORMAT json_sensor_format
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE;
```

Lambda writes a JSON **array**:
```json
[{"device_id": "DEV_001", ...}, {"device_id": "DEV_002", ...}]
```

Without `STRIP_OUTER_ARRAY`:
- 1 row loaded, containing the entire array as one VARIANT

With `STRIP_OUTER_ARRAY = TRUE`:
- 50 rows loaded, each array element becomes its own row

---

## 4. Snowpipe (04_pipes.sql)

```sql
CREATE PIPE sensor_readings_pipe AUTO_INGEST = TRUE AS
    COPY INTO sensor_readings ...
```

Snowpipe is **event-driven** loading:
1. Lambda writes file to S3
2. S3 sends event to an SQS queue (created by Snowflake)
3. Snowpipe detects the event and runs `COPY INTO`
4. Data appears in ~60 seconds

**vs. scheduled loading (Airflow)**:
- Snowpipe: near-real-time, automatic, serverless
- Airflow COPY INTO: scheduled, controlled, auditable

We have both — Snowpipe as a safety net, Airflow as the primary orchestrator.

---

## 5. Streams — Change Data Capture (05_streams.sql)

```sql
CREATE STREAM sensor_readings_stream
    ON TABLE sensor_readings
    APPEND_ONLY = TRUE;
```

A Stream is like a **bookmark** on a table. It tracks which rows are new since you last looked.

```
Time 1: Load 50 rows → Stream shows 50 new rows
Time 2: Read stream   → Stream advances, shows 0 rows
Time 3: Load 50 more  → Stream shows 50 new rows again
```

`APPEND_ONLY = TRUE` means we only track INSERTs (not updates/deletes), which is all we need for raw data.

**Why use streams?**
- Know exactly what's new without tracking timestamps yourself
- Pairs with Tasks for fully autonomous processing inside Snowflake
- Works even if Airflow is down

---

## 6. Tasks — Autonomous Scheduling (06_tasks.sql)

```sql
CREATE TASK check_raw_freshness
    WAREHOUSE = IOT_WH
    SCHEDULE = 'USING CRON 0,30 * * * * UTC'
AS
    INSERT INTO freshness_log ...;
```

Tasks are Snowflake's built-in cron scheduler. They run SQL on a schedule.

Our task checks freshness every 30 minutes:
- "When was the last row loaded into `sensor_readings`?"
- "Is that within 60 minutes?" → `is_fresh = TRUE/FALSE`

This runs **independently of Airflow**. If Airflow crashes, Snowflake still monitors.

---

## 7. Iceberg Tables (07_iceberg.sql)

```sql
CREATE EXTERNAL VOLUME iot_iceberg_volume
    STORAGE_LOCATIONS = (
        ( STORAGE_BASE_URL = 's3://iot-fleet-monitor-data/iceberg/' ... )
    );

CREATE ICEBERG TABLE MARTS.fct_hourly_readings (...)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'iot_iceberg_volume'
    BASE_LOCATION = 'marts/fct_hourly_readings/';
```

**What Iceberg does**:
- Data stored as **Parquet files** on S3 (columnar, compressed, fast)
- Metadata stored as **Iceberg manifests** on S3 (tracks which Parquet files exist, column stats)
- Snowflake manages both, but everything lives on YOUR S3

**Why this matters**:
- Without Iceberg: data locked inside Snowflake. Only accessible via Snowflake.
- With Iceberg: Parquet files on S3. Spark, Trino, Athena, DuckDB can all read them directly.

**Catalog = 'SNOWFLAKE'** means Snowflake manages the Iceberg metadata. Alternative is using an external catalog like AWS Glue.

---

## 8. RBAC — Role-Based Access Control (00_setup.sql)

```
IOT_LOADER      → Can write to RAW, read stages
IOT_TRANSFORMER → Can read RAW, write STAGING/INTERMEDIATE/MARTS
IOT_READER      → Read-only on MARTS
```

**Least privilege**: each role has exactly the permissions it needs. The Lambda/Airflow loader uses `IOT_LOADER` — it can put data in RAW but can't touch mart tables. dbt uses `IOT_TRANSFORMER`. BI tools use `IOT_READER`.

If the loader credential is compromised, attackers can only write to RAW — not modify business-critical mart data.

---

## Script Execution Order

Run these in order (each depends on the previous):

```
00_setup.sql         → Database, schemas, roles, warehouse
01_stages.sql        → Storage integration, external stage (needs AWS IAM setup after)
02_file_formats.sql  → JSON file format
03_raw_tables.sql    → VARIANT raw tables
04_pipes.sql         → Snowpipe (optional)
05_streams.sql       → CDC streams
06_tasks.sql         → Freshness monitoring
07_iceberg.sql       → Iceberg external volume (needs AWS IAM setup after)
```
