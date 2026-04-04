# Project Specification — IoT Fleet Monitor Pipeline

## Domain

An industrial IoT fleet of **50 sensor devices** deployed across 5 geographic clusters (factory floors, warehouses, outdoor stations). Each device reports every **5 minutes**:

| Metric | Unit | Normal Range | Description |
|--------|------|-------------|-------------|
| Temperature | °C | -20 to 60 | Ambient temperature |
| Humidity | % | 10 to 95 | Relative humidity |
| Pressure | hPa | 950 to 1050 | Atmospheric pressure |
| Battery | % | 0 to 100 | Device battery level (slowly draining) |
| Latitude | ° | varies by cluster | GPS latitude |
| Longitude | ° | varies by cluster | GPS longitude |

**Daily volume**: 50 devices × 288 readings/day = **14,400 readings/day**

---

## Device Fleet

### Cluster Locations

| Cluster | Location | Devices | Environment |
|---------|----------|---------|-------------|
| FACTORY_A | 40.7128, -74.0060 (NYC) | DEV_001–DEV_010 | Indoor, stable temp |
| FACTORY_B | 34.0522, -118.2437 (LA) | DEV_011–DEV_020 | Indoor, warm |
| WAREHOUSE_A | 41.8781, -87.6298 (Chicago) | DEV_021–DEV_030 | Semi-outdoor, variable |
| WAREHOUSE_B | 29.7604, -95.3698 (Houston) | DEV_031–DEV_040 | Semi-outdoor, humid |
| OUTDOOR | 47.6062, -122.3321 (Seattle) | DEV_041–DEV_050 | Outdoor, rain/cold |

Each device has:
- A unique `device_id` (e.g., `DEV_001`)
- A `device_type` (Type A, B, or C — different sensor hardware)
- A `firmware_version` (for schema drift simulation)
- An `install_date` and `cluster_id`

---

## Data Flow

### 1. Generation (Lambda)
- Triggered on schedule or on-demand via Airflow
- Generates readings for all 50 devices for a given time window
- Uses **random walk** for temperature/humidity/pressure (values drift realistically between readings)
- Battery drains gradually (~0.1% per reading, recharges at thresholds)
- GPS has slight jitter around cluster center
- Applies error injection based on selected profile

### 2. Landing (S3 — Raw JSON)
- Path: `s3://{bucket}/sensor_readings/year=YYYY/month=MM/day=DD/hour=HH/batch_{timestamp}.json`
- Each file contains an array of reading objects
- Hive-style partitioning for efficient loading

### 3. Ingestion (Snowflake RAW)
- `COPY INTO` from S3 stage into VARIANT column
- Raw table stores the entire JSON payload as-is
- Snowpipe available for auto-ingest (optional)
- Streams track CDC for downstream processing

### 4. Transformation (dbt)

#### Staging
- Parse VARIANT JSON into typed columns using `TRY_CAST`
- Apply safe extraction macros for nested fields
- Source freshness checks

#### Intermediate
- **Deduplication**: Window function to remove exact and near-duplicates
- **Validation**: Range checks against `sensor_thresholds` seed, z-score anomaly flagging
- **Enrichment**: Join device metadata, add time dimensions (hour_of_day, day_of_week, is_weekend)
- **Quarantine**: Bad records isolated with array of rejection reason codes
- **Late arrivals**: Records arriving after their expected window, handled in incremental merge

#### Marts
- **dim_devices**: Device dimension from seed + SCD Type 2 snapshot
- **fct_hourly_readings**: Aggregated hourly metrics (avg, min, max, stddev, count)
- **fct_device_health**: Battery trends, uptime %, alert status
- **fct_anomalies**: Anomaly event log with classification
- **fct_data_quality**: Quality scorecard per batch (null %, OOR %, dupe %, total records)
- **rpt_fleet_overview**: Executive summary (fleet-wide health, top issues, SLA compliance)

### 5. Curated Storage (S3 — Apache Iceberg / Parquet)
- Mart tables configured as **Snowflake-managed Iceberg tables**
- Data physically stored as **Parquet files on S3** in Iceberg format
- Iceberg metadata (manifests, snapshots) managed by Snowflake
- Benefits:
  - **Open format**: queryable by Spark, Trino, Athena, DuckDB — not locked in Snowflake
  - **Time travel**: query historical snapshots via Iceberg metadata
  - **Schema evolution**: add columns without rewriting data
  - **Efficient pruning**: Iceberg metadata enables min/max column statistics for fast scans
- External catalog path: `s3://{bucket}/iceberg/iot_pipeline/`

### 6. Orchestration (Airflow)
- **Main DAG** (`iot_pipeline_dag`): trigger_lambda → wait_for_data → load → dbt_staging → dbt_intermediate → quality_check → branch(pass/fail) → dbt_marts or alert
- **Monitoring DAG** (`iot_monitoring_dag`): hourly freshness and health checks
- TaskFlow API with `@task.branch()` for quality-based routing
- Airflow Params for runtime error profile selection
- SLA enforcement with callbacks

### 7. Monitoring
- Quality dashboard queries for Snowsight
- Alert rules with configurable thresholds
- Row count anomaly detection (custom dbt generic test)

---

## Snowflake Object Model

```
IOT_PIPELINE (database)
├── RAW (schema)
│   ├── sensor_readings      — VARIANT column, raw JSON
│   └── load_audit_log       — Load metadata tracking
├── STAGING (schema)
│   ├── stg_sensor_readings  — Parsed, typed columns
│   └── stg_device_metadata  — Parsed device info
├── INTERMEDIATE (schema)
│   ├── int_readings_deduped     — Deduplicated
│   ├── int_readings_validated   — Range + anomaly checked
│   ├── int_readings_enriched    — Joined + time dimensions
│   ├── int_quarantined_readings — Bad records + reasons
│   └── int_late_arriving_readings — Late data
├── MARTS (schema) — Iceberg tables (Parquet on S3)
│   ├── dim_devices          — Device dimension (SCD2)
│   ├── fct_hourly_readings  — Aggregated metrics
│   ├── fct_device_health    — Battery, uptime, alerts
│   ├── fct_anomalies        — Anomaly event log
│   ├── fct_data_quality     — Quality scorecard
│   └── rpt_fleet_overview   — Executive summary
└── MONITORING (schema)
    └── freshness_log        — Automated freshness checks
```

### Roles
- `IOT_LOADER` — Can write to RAW, read stages
- `IOT_TRANSFORMER` — Can read RAW, write to STAGING/INTERMEDIATE/MARTS
- `IOT_READER` — Read-only on MARTS (for BI tools)

### Warehouse
- `IOT_WH` — X-Small, auto-suspend 60s

---

## Technology Versions

| Technology | Version |
|-----------|---------|
| Python | 3.11 |
| Apache Airflow | 3.1.3 |
| dbt-core | latest compatible |
| dbt-snowflake | latest compatible |
| Pydantic | v2 |
| sqlfluff | latest |
| ruff | latest |
