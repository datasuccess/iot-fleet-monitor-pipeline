# Implementation Plan — IoT Fleet Monitor Pipeline

## Architecture

```
Lambda (generate data) → S3 (raw JSON) → Snowflake RAW (VARIANT)
                                              ↓
                                         dbt transforms
                                    (staging → intermediate → marts)
                                              ↓
                                   Snowflake-managed Iceberg Tables
                                     (Parquet files on S3)
                                              ↓
                                      Monitoring & Alerts

               Airflow orchestrates every step
```

---

## Phase 1: Lambda Data Generator + S3

**Goal**: Generate realistic IoT sensor data and land it as partitioned JSON in S3.

**Files**:
| File | Purpose |
|------|---------|
| `lambda/data_generator/handler.py` | Lambda entry point, writes JSON to S3 |
| `lambda/data_generator/config.py` | Device count, sensor ranges, error profiles |
| `lambda/data_generator/models.py` | Pydantic v2 models for sensor readings |
| `lambda/data_generator/devices.py` | 50-device fleet registry with 5 location clusters |
| `lambda/data_generator/sensors.py` | Random walk time-series generators |
| `lambda/data_generator/errors.py` | Error injection (nulls, OOR, dupes, late arrivals, schema drift) |
| `lambda/deploy.sh` | Create S3 bucket, IAM role, deploy Lambda |
| `lambda/requirements.txt` | pydantic, boto3 |
| `lambda/tests/test_generator.py` | Local unit tests |

**S3 path**: `sensor_readings/year=YYYY/month=MM/day=DD/hour=HH/batch_{ts}.json`

**Error profiles**:
| Profile | Nulls | Out-of-Range | Duplicates |
|---------|-------|-------------|------------|
| `none` | 0% | 0% | 0% |
| `normal` | 3% | 2% | 5% |
| `high` | 10% | 8% | 15% |
| `chaos` | 25% | 15% | 30% |

**Concepts learned**: Pydantic validation, random walk algorithms, configurable error injection, S3 Hive-style partitioning

---

## Phase 2: Snowflake Setup

**Goal**: Create Snowflake objects — database, schemas, roles, stages, pipes, streams, tasks, and Iceberg table configuration.

**Files**:
| File | Purpose |
|------|---------|
| `snowflake/00_setup.sql` | Database, schemas, roles (IOT_LOADER, IOT_TRANSFORMER, IOT_READER), warehouse |
| `snowflake/01_stages.sql` | Storage integration, external stage to S3 |
| `snowflake/02_file_formats.sql` | JSON format with STRIP_OUTER_ARRAY |
| `snowflake/03_raw_tables.sql` | VARIANT-based raw tables |
| `snowflake/04_pipes.sql` | Snowpipe auto-ingest definitions |
| `snowflake/05_streams.sql` | CDC streams on raw tables |
| `snowflake/06_tasks.sql` | Autonomous freshness monitoring |
| `snowflake/07_iceberg.sql` | External volume, catalog integration, Iceberg table DDL for marts |

**Concepts learned**: VARIANT columns, Snowpipe, Streams (CDC), Tasks, RBAC, Apache Iceberg tables in Snowflake

---

## Phase 3: Basic Airflow DAG (Lambda → Load)

**Goal**: Minimal Airflow setup that triggers Lambda and loads data into Snowflake.

**Files**:
| File | Purpose |
|------|---------|
| `airflow/docker-compose.yml` | Postgres + Airflow standalone |
| `airflow/Dockerfile` | Based on apache/airflow:3.1.3-python3.11 |
| `airflow/requirements.txt` | dbt-snowflake, boto3, providers |
| `airflow/dags/iot_pipeline_dag.py` | Minimal: trigger_lambda → load_to_snowflake → validate |
| `airflow/dags/helpers/lambda_utils.py` | Lambda invocation with retry |
| `airflow/dags/helpers/snowflake_utils.py` | COPY INTO wrapper |

**Concepts learned**: TaskFlow API, XCom, Airflow pools, Docker Compose

---

## Phase 4: dbt Staging Models

**Goal**: Parse semi-structured VARIANT data into typed staging models.

**Files**:
| File | Purpose |
|------|---------|
| `dbt/iot_pipeline/dbt_project.yml` | Project config |
| `dbt/iot_pipeline/profiles.yml` | Snowflake connection |
| `dbt/iot_pipeline/packages.yml` | dbt_utils, dbt_expectations |
| `dbt/iot_pipeline/models/staging/_sources.yml` | Source definitions + freshness checks |
| `dbt/iot_pipeline/models/staging/_staging.yml` | dbt_expectations tests |
| `dbt/iot_pipeline/models/staging/stg_sensor_readings.sql` | Parse VARIANT JSON with TRY_CAST |
| `dbt/iot_pipeline/models/staging/stg_device_metadata.sql` | Parse device metadata |
| `dbt/iot_pipeline/macros/generate_schema_name.sql` | Custom schema naming |
| `dbt/iot_pipeline/macros/parse_json_field.sql` | Safe VARIANT extraction macro |
| `dbt/iot_pipeline/seeds/device_registry.csv` | 50 devices reference data |
| `dbt/iot_pipeline/seeds/sensor_thresholds.csv` | Valid ranges per sensor |

**Concepts learned**: VARIANT parsing, TRY_CAST, source freshness, dbt_expectations, custom macros, seeds

---

## Phase 5: dbt Intermediate + Marts + Snapshots

**Goal**: Full transformation layer — dedup, validate, enrich, quarantine, aggregate, snapshot.

**Intermediate models**:
| Model | Purpose |
|-------|---------|
| `int_readings_deduped.sql` | Incremental dedup via window functions |
| `int_readings_validated.sql` | Range checks + z-score anomaly flagging |
| `int_readings_enriched.sql` | Join device metadata, add time dimensions |
| `int_quarantined_readings.sql` | Bad records with rejection reason array |
| `int_late_arriving_readings.sql` | Late data handling |

**Mart models** (Iceberg tables):
| Model | Purpose |
|-------|---------|
| `dim_devices.sql` | Device dimension from seed + SCD2 snapshot |
| `fct_hourly_readings.sql` | Aggregated hourly metrics |
| `fct_device_health.sql` | Battery trends, uptime, alert status |
| `fct_anomalies.sql` | Anomaly event log |
| `fct_data_quality.sql` | Quality scorecard per batch |
| `rpt_fleet_overview.sql` | Executive summary |

**Supporting files**: `snap_device_metadata.sql`, macros (`deduplicate.sql`, `classify_anomaly.sql`, `safe_cast_numeric.sql`), custom singular tests

**Concepts learned**: Incremental models, SCD Type 2, z-score anomaly detection in SQL, quarantine pattern, window functions

---

## Phase 6: Full Airflow Orchestration

**Goal**: Production-grade DAG with branching, sensors, SLA enforcement, and runtime parameters.

**Updates to** `iot_pipeline_dag.py`:
- `@task.branch()` for quality-based routing
- `@task.sensor()` for S3 data availability
- SLA enforcement, trigger rules, exponential backoff
- Airflow Params for runtime error profile selection
- Success/failure callbacks

**New files**:
| File | Purpose |
|------|---------|
| `airflow/dags/iot_monitoring_dag.py` | Hourly monitoring DAG |
| `airflow/dags/helpers/notify.py` | Callback functions |
| `airflow/dags/helpers/dbt_utils.py` | dbt subprocess wrapper |
| `airflow/plugins/sensors/s3_file_count_sensor.py` | Custom S3 file count sensor |

**Concepts learned**: @task.branch, @task.sensor, SLA, trigger rules, Params, structured logging

---

## Phase 7: Monitoring & Data Quality Framework

**Goal**: Observability layer — dashboards, alerts, linting, pre-commit hooks.

**Files**:
| File | Purpose |
|------|---------|
| `monitoring/dashboards/quality_dashboard.sql` | Snowsight queries |
| `monitoring/alerts/alert_rules.yml` | Threshold configs |
| `dbt/iot_pipeline/macros/test_row_count_anomaly.sql` | Custom generic test |
| `.pre-commit-config.yaml` | sqlfluff + ruff |
| `.sqlfluff` | Snowflake dialect config |
| `.env.example` | Environment variable template |
| `scripts/run_daily.sh` | Daily trigger script |

**Concepts learned**: Data observability, row count anomaly detection, pre-commit hooks, sqlfluff

---

## Phase 8: 5-Day Production Run

**Goal**: Validate the full pipeline under escalating error conditions.

| Day | Error Profile | What to Observe |
|-----|--------------|-----------------|
| 1 | `none` | Baseline metrics, clean data flow |
| 2 | `normal` | Quality catches working, small quarantine |
| 3 | `high` | Alerts fire, quarantine grows |
| 4 | `chaos` | Pipeline resilience, SLA misses |
| 5 | `normal` | Recovery, trend normalization |

**Review**: `fct_data_quality` trends, `fct_anomalies` log, SCD Type 2 history, incremental model behavior

---

## Iceberg Integration Details

Apache Iceberg is integrated at the **mart layer**:

1. **External Volume**: S3 bucket + path configured as Snowflake external volume
2. **Catalog Integration**: Snowflake-managed catalog writes Iceberg metadata
3. **Iceberg Tables**: Mart models (`dim_devices`, `fct_*`, `rpt_*`) created as Iceberg tables
4. **Storage**: Data written as **Parquet files** on S3, metadata as Iceberg manifests
5. **Benefits**:
   - Open format — queryable by Spark, Trino, Athena, DuckDB without Snowflake
   - Time travel — query previous snapshots
   - Schema evolution — add columns without rewriting
   - Efficient pruning — column min/max stats in metadata
6. **dbt integration**: Use `{{ config(materialized='table') }}` with Snowflake Iceberg table DDL in post-hooks or custom materialization
