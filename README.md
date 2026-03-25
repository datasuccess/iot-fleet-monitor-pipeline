# IoT Fleet Monitor Pipeline

An end-to-end data engineering pipeline that ingests, processes, and monitors IoT sensor data from a fleet of 50 devices — built with **AWS Lambda**, **S3**, **Apache Iceberg**, **Snowflake**, **dbt**, and **Apache Airflow**.

## Architecture

```
Lambda (generate data)
    ↓
S3 — Raw JSON (landing zone)
    ↓
Snowflake RAW schema (VARIANT columns)
    ↓
dbt transformations (staging → intermediate → marts)
    ↓
Snowflake-managed Iceberg Tables (Parquet on S3)
    ↓
Monitoring & Data Quality
```

Airflow orchestrates every step.

## What This Pipeline Does

- **Generates** realistic IoT sensor data (temperature, humidity, pressure, battery, GPS) from 50 devices every 5 minutes
- **Injects** configurable data quality errors (nulls, out-of-range, duplicates, late arrivals) to simulate real-world conditions
- **Lands** raw JSON in S3 with Hive-style partitioning
- **Loads** into Snowflake RAW schema as semi-structured VARIANT data
- **Transforms** through dbt layers: parsing, deduplication, validation, enrichment, aggregation
- **Stores** curated mart data as Apache Iceberg tables (Parquet format on S3) — open, portable, queryable by any engine
- **Monitors** data quality with automated anomaly detection, quarantine patterns, and freshness checks
- **Snapshots** device metadata changes using SCD Type 2

## Key Technologies

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Data Generation | AWS Lambda + Python | Simulate 50-device IoT fleet |
| Raw Storage | S3 (JSON) | Partitioned landing zone |
| Curated Storage | S3 (Apache Iceberg / Parquet) | Open table format for mart data |
| Data Warehouse | Snowflake | VARIANT ingestion, Iceberg table management |
| Transformation | dbt | Staging → Intermediate → Marts |
| Orchestration | Apache Airflow | DAG scheduling, branching, SLA enforcement |
| Quality | dbt tests + dbt_expectations | Automated validation and anomaly detection |
| Linting | sqlfluff + ruff | Code quality enforcement |

## Advanced Concepts Covered

- **Apache Iceberg** — open table format with Parquet storage, schema evolution, time travel
- **Semi-structured data** — Snowflake VARIANT columns, TRY_CAST parsing
- **Time-series generation** — random walk algorithms (not pure random)
- **Configurable error injection** — 4 profiles: `none`, `normal`, `high`, `chaos`
- **Incremental models** — efficient deduplication and late-arriving data handling
- **SCD Type 2** — device metadata change tracking via dbt snapshots
- **Statistical anomaly detection** — z-score based flagging in SQL
- **Quarantine pattern** — bad records isolated with rejection reasons
- **Snowpipe & Streams** — auto-ingest and CDC concepts
- **TaskFlow API** — `@task.branch()`, `@task.sensor()`, Params, SLA enforcement
- **Data observability** — quality scorecards, freshness monitoring, row count anomaly tests

## Error Profiles

| Profile | Nulls | Out-of-Range | Duplicates | Use Case |
|---------|-------|-------------|------------|----------|
| `none` | 0% | 0% | 0% | Baseline testing |
| `normal` | 3% | 2% | 5% | Day-to-day simulation |
| `high` | 10% | 8% | 15% | Stress testing |
| `chaos` | 25% | 15% | 30% | Resilience testing |

## Project Structure

```
iot-fleet-monitor-pipeline/
├── lambda/                  # Data generator (AWS Lambda)
├── snowflake/               # DDL scripts (setup, stages, pipes, streams, tasks)
├── dbt/iot_pipeline/        # dbt project (models, macros, seeds, snapshots, tests)
├── airflow/                 # DAGs, helpers, plugins, Docker setup
├── monitoring/              # Dashboard queries, alert configs
├── scripts/                 # Utility scripts
├── PROJECT.md               # Detailed project specification
├── DATA_MODEL.md            # Entity relationship diagrams
├── TODO.md                  # Implementation progress tracker
└── PLAN.md                  # Phase-by-phase implementation plan
```

## Getting Started

> This project is currently in the **planning phase**. Implementation instructions will be added as each phase is completed.

## 5-Day Production Run

After full implementation, the pipeline runs for 5 days with escalating error profiles to validate resilience:

| Day | Profile | Goal |
|-----|---------|------|
| 1 | `none` | Establish baseline metrics |
| 2 | `normal` | Observe quality catches working |
| 3 | `high` | Stress test, verify alerts fire |
| 4 | `chaos` | Pipeline resilience under extreme errors |
| 5 | `normal` | Verify recovery and trend normalization |
