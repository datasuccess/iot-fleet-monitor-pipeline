# Pipeline Recovery — How COPY INTO Catches Up Automatically

## The Scenario

Lambda runs every hour via EventBridge, writing JSON to S3. Airflow is paused (crashed, maintenance, EC2 rebooted, etc). After 3 hours, you notice and unpause Airflow. What happens?

---

## Timeline

```
HOUR 10   Lambda → S3 file (hour=10)     Airflow PAUSED
HOUR 11   Lambda → S3 file (hour=11)     Airflow PAUSED        Snowflake task: WARNING
HOUR 12   Lambda → S3 file (hour=12)     Airflow PAUSED        Snowflake task: CRITICAL
                                          Streamlit: Pipeline DOWN

HOUR 12:30  You see the alert, unpause Airflow

HOUR 13   Airflow runs:
           1. COPY INTO → loads 3 files (hour=10,11,12) in ONE operation
           2. validate_load → has_new_data=True, 150 rows
           3. branch → start_dbt
           4. dbt processes all 150 rows through staging → intermediate → marts
           5. Pipeline health view → HEALTHY again
           6. Streamlit: Pipeline healthy
```

Zero custom recovery code. No backfill scripts. No "replay missed hours" logic.

---

## The Recovery Chain: 4 Systems Working Together

### Part 1: Lambda (Producer) — Never Knows Airflow Exists

**File**: `lambda/data_generator/handler.py` (lines 78-123)

```python
def lambda_handler(event, context):
    # EventBridge calls this every hour, no matter what
    reading_ts = datetime.now(timezone.utc)
    readings = generate_batch(reading_ts, error_profile)

    # Writes JSON to S3 with time-partitioned path
    s3_key = _s3_key(reading_ts)
    # e.g., sensor_readings/year=2026/month=03/day=30/hour=10/batch_...json
    s3.put_object(Bucket=bucket, Key=s3_key, Body=json.dumps(readings))
```

Lambda doesn't call Airflow, doesn't check if Airflow is running, doesn't care. EventBridge triggers it every hour. It writes to S3 and exits. The files accumulate in S3 like an inbox — they sit there until someone reads them.

---

### Part 2: S3 Stage — The Bridge Between Lambda and Snowflake

**File**: `snowflake/01_stages.sql` (lines 39-42)

```sql
CREATE STAGE IF NOT EXISTS raw_sensor_stage
    STORAGE_INTEGRATION = iot_s3_integration
    URL = 's3://iot-fleet-monitor-data/sensor_readings/';
```

This stage is just a pointer — "Snowflake, when I reference `@raw_sensor_stage`, look at this S3 path." It doesn't copy anything. It's a window into S3.

After 3 hours of downtime, `LIST @raw_sensor_stage` would show ALL files, including the 3 Lambda wrote while Airflow was paused.

---

### Part 3: The Raw Table — Where Data Lands

**File**: `snowflake/03_raw_tables.sql` (lines 21-25)

```sql
CREATE TABLE IF NOT EXISTS sensor_readings (
    raw_data        VARIANT,                                  -- Entire JSON
    loaded_at       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(), -- When Snowflake loaded it
    source_file     VARCHAR                                    -- Which S3 file
);
```

Three columns. The JSON goes into `raw_data` as VARIANT. `loaded_at` is when **Snowflake** loaded it (not when the sensor read it). `source_file` tracks which S3 file each row came from — critical for debugging.

---

### Part 4: COPY INTO — The Magic Recovery Command

**File**: `airflow/dags/iot_pipeline_dag.py` (lines 71-106)

```python
@task()
def load_new_data() -> dict:
    copy_sql = """
        COPY INTO IOT_PIPELINE.RAW.sensor_readings (raw_data, loaded_at, source_file)
        FROM (
            SELECT
                $1,                        -- The JSON content
                CURRENT_TIMESTAMP(),       -- When we're loading it NOW
                METADATA$FILENAME          -- S3 file path
            FROM @IOT_PIPELINE.RAW.raw_sensor_stage
        )
        FILE_FORMAT = IOT_PIPELINE.RAW.json_sensor_format
        PATTERN = '.*\\.json'
        ON_ERROR = 'CONTINUE';
    """
    result = run_snowflake_query(copy_sql)
```

**This is the heart of recovery.** Here's what Snowflake does internally:

1. Lists ALL `.json` files in `@raw_sensor_stage` (every file in S3)
2. Checks its internal **metadata table**: "Which of these files have I already loaded into `sensor_readings`?"
3. **Skips files already loaded**
4. **Loads only NEW files**

After 3 hours of downtime:

```
COPY INTO scans the stage:
  - batch_20260330_080000.json → Already in metadata → SKIP
  - batch_20260330_090000.json → Already in metadata → SKIP
  - batch_20260330_100000.json → NOT in metadata → LOAD ✓
  - batch_20260330_110000.json → NOT in metadata → LOAD ✓
  - batch_20260330_120000.json → NOT in metadata → LOAD ✓

Result: 3 new files, 150 rows (50 devices × 3 hours)
```

**One single COPY INTO loads ALL missed data in one shot.** No loops, no "for each missed hour" logic. One command.

Run it again? Loads 0 files — all files are now in the metadata. **Idempotent.**

### How Snowflake File Metadata Works

Snowflake stores a hidden metadata record for every file loaded via COPY INTO:
- File name
- File size
- File checksum (ETag)
- Load timestamp

This metadata is kept for **64 days** by default. If a file with the same name, size, and checksum appears again, COPY INTO silently skips it. This is what makes the whole recovery pattern work — you don't need to track "what did I already load" yourself.

> **Note**: If you need to re-load a file (e.g., it was corrupted and you fixed it), use `COPY INTO ... FORCE = TRUE` to bypass the metadata check.

---

### Part 5: Airflow Reads The Result

**File**: `airflow/dags/iot_pipeline_dag.py` (lines 96-106)

```python
    # COPY INTO returns one row per file: (file, status, rows_parsed, rows_loaded, ...)
    files_loaded = len(result) if result else 0          # 3 files
    rows_loaded = sum(row[3] for row in result) if result else 0  # 150 rows

    return {
        "files_loaded": files_loaded,   # 3
        "rows_loaded": rows_loaded,     # 150
    }
```

---

### Part 6: Validation Confirms Recovery

**File**: `airflow/dags/iot_pipeline_dag.py` (lines 108-139)

```python
@task()
def validate_load(load_result: dict) -> dict:
    count_sql = """
        SELECT
            COUNT(*) AS total_rows,
            COUNT(DISTINCT source_file) AS total_files,
            MAX(loaded_at) AS latest_load
        FROM IOT_PIPELINE.RAW.sensor_readings;
    """
    return {
        "new_files": new_files,       # 3 (recovery batch)
        "new_rows": new_rows,         # 150
        "total_rows": total_rows,     # e.g., 750 (all time)
        "has_new_data": new_rows > 0, # True → triggers dbt
    }
```

`has_new_data` is `True` because we loaded 150 new rows.

---

### Part 7: Branch Runs dbt

**File**: `airflow/dags/iot_pipeline_dag.py` (lines 141-155)

```python
@task.branch()
def branch_on_quality(validation_result: dict, **context) -> str:
    has_new_data = validation_result.get("has_new_data", False)  # True
    run_dbt = context["params"].get("run_dbt", True)             # True

    if has_new_data and run_dbt:
        return "start_dbt"    # ← Takes this path after recovery
```

Since we loaded 150 new rows, it branches to `start_dbt` → Cosmos runs every dbt model → staging parses the JSON → intermediate deduplicates/validates → marts aggregate. **All 3 hours of data processed in one dbt run.**

---

### Part 8: Detection — Pipeline Health View

**File**: `snowflake/09_pipeline_health.sql` (lines 11-43)

This runs **inside Snowflake**, independent of Airflow:

```sql
CREATE OR REPLACE VIEW IOT_PIPELINE.MONITORING.pipeline_health AS
SELECT
    MAX(loaded_at) AS last_snowflake_load,

    -- "How many minutes since Airflow last loaded data?"
    DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) AS minutes_since_last_load,

    -- Status based on staleness
    CASE
        WHEN DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) <= 90 THEN 'HEALTHY'
        WHEN DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) <= 180 THEN 'WARNING'
        ELSE 'CRITICAL'
    END AS pipeline_status,

    -- Estimated missed batches (hourly schedule)
    GREATEST(0, ROUND(DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) / 60.0) - 1)
        AS estimated_missed_batches

FROM IOT_PIPELINE.RAW.sensor_readings;
```

It looks at `loaded_at` — when Snowflake last ran COPY INTO. If `loaded_at` is 3 hours old, it knows Airflow hasn't loaded data in 3 hours, even though Lambda kept writing to S3.

The Snowflake **task** checks every 30 minutes automatically:

```sql
CREATE OR REPLACE TASK IOT_PIPELINE.MONITORING.check_pipeline_health
    WAREHOUSE = IOT_WH
    SCHEDULE = '30 MINUTE'
AS
    SELECT pipeline_status, status_message, estimated_missed_batches
    FROM IOT_PIPELINE.MONITORING.pipeline_health
    WHERE pipeline_status != 'HEALTHY';
```

---

### Part 9: Streamlit Dashboard Shows The Alert

**File**: `streamlit_snowflake/Fleet_Monitor.py` — Banner at the top:

```python
ph = run_query("SELECT * FROM IOT_PIPELINE.MONITORING.pipeline_health")
status = p["pipeline_status"]

if status == "CRITICAL":
    st.error("Pipeline DOWN — No data loaded for X minutes. ~Y batches missed.")
```

**File**: `streamlit_snowflake/pages/Pipeline_Admin.py` — Detailed recovery steps:

```python
if status == "CRITICAL":
    st.error(p["status_message"])
    st.markdown("""
    Recovery steps:
    1. Check Airflow — is the DAG paused? Is the scheduler running?
    2. Unpause the DAG — COPY INTO will automatically load all missed S3 files
    3. Snowflake tracks loaded files, so no duplicates
    4. dbt will process everything in the next run
    """)
```

---

## Why NOT catchup=True?

Our DAG has `catchup=False`. Here's why:

| Approach | What Happens After 3 Hours Down | Pros | Cons |
|----------|-------------------------------|------|------|
| `catchup=True` | Airflow creates 3 separate DAG runs (hour 10, 11, 12), each running COPY INTO separately | Preserves per-hour granularity in Airflow logs | 3 COPY INTO calls (first loads all 3 files, other 2 load 0 files — wasted warehouse time). Resource spike. Can overwhelm scheduler. |
| `catchup=False` | One DAG run, one COPY INTO loads all 3 files at once | Efficient, clean, single recovery batch | Airflow only shows 1 run (but Snowflake has the per-file detail via `source_file`) |

`catchup=False` is the right choice here because:
1. COPY INTO already handles "load what's new" — we don't need Airflow to replay each hour
2. No resource spike from 3 simultaneous DAG runs
3. dbt incremental models process all new rows regardless of how many hours they span
4. `source_file` column preserves the per-hour provenance if you need to debug

### When catchup=True IS Appropriate
- When each DAG run does something unique per time window (e.g., calling an API with a date range)
- When you need Airflow-level tracking of each individual time slot
- When your loading logic is NOT idempotent (ours is, so we don't need it)

---

## Key Design Decisions

1. **VARIANT column** (not typed columns) — Schema drift in S3 files can't break loading. Parsing happens in dbt with TRY_CAST.
2. **`loaded_at` vs `reading_ts`** — `loaded_at` is when Snowflake loaded it; `reading_ts` is inside the JSON (when the sensor read it). Pipeline health checks `loaded_at` because that tells you when Airflow last ran.
3. **`source_file` column** — After recovery, you can query `SELECT DISTINCT source_file FROM sensor_readings WHERE loaded_at > '2026-03-30 13:00:00'` to see exactly which S3 files were in the recovery batch.
4. **ON_ERROR = 'CONTINUE'** — If one file is corrupt, the others still load. The error is logged but doesn't block recovery.
5. **64-day metadata window** — Snowflake remembers loaded files for 64 days. If you need to recover data older than 64 days, you'd need `FORCE = TRUE` (and handle dedup yourself).

---

## Quick Reference: Recovery Commands

```sql
-- Check pipeline health right now
SELECT * FROM IOT_PIPELINE.MONITORING.pipeline_health;

-- See what files are in S3 waiting to be loaded
LIST @IOT_PIPELINE.RAW.raw_sensor_stage;

-- See what's already been loaded (most recent)
SELECT DISTINCT source_file, loaded_at
FROM IOT_PIPELINE.RAW.sensor_readings
ORDER BY loaded_at DESC
LIMIT 20;

-- Manual COPY INTO (if you want to load without waiting for Airflow)
COPY INTO IOT_PIPELINE.RAW.sensor_readings (raw_data, loaded_at, source_file)
FROM (
    SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME
    FROM @IOT_PIPELINE.RAW.raw_sensor_stage
)
FILE_FORMAT = IOT_PIPELINE.RAW.json_sensor_format
PATTERN = '.*\.json'
ON_ERROR = 'CONTINUE';

-- Verify what the recovery batch loaded
SELECT source_file, COUNT(*) AS rows_loaded, MIN(loaded_at) AS loaded_at
FROM IOT_PIPELINE.RAW.sensor_readings
WHERE loaded_at > DATEADD(hour, -1, CURRENT_TIMESTAMP())
GROUP BY source_file
ORDER BY source_file;
```
