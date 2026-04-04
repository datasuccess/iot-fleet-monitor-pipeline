# Testing Strategy — IoT Fleet Monitor Pipeline

## Overview

Six types of tests, applied across different phases:

| Test Type | What it Tests | Phase | Tool |
|-----------|--------------|-------|------|
| **Unit** | Individual functions in isolation | 1 | pytest |
| **Integration** | Components working together (Lambda→S3, S3→Snowflake) | 2, 3 | pytest + boto3 |
| **Contract** | Schema matches expectations (columns, types, not-null) | 4 | dbt tests |
| **Data Quality** | Business rules (ranges, uniqueness, freshness) | 4, 5 | dbt_expectations |
| **Regression** | Row counts, aggregates don't change unexpectedly | 5 | custom dbt generic tests |
| **Pipeline** | Full DAG runs correctly end-to-end | 6 | Airflow test commands |

---

## Phase 1 — Unit Tests (done)
**Location**: `lambda/tests/test_generator.py`

Tests individual functions:
- Fleet has 50 devices, correct IDs, correct clusters
- Random walk stays within sensor bounds
- Error profiles generate expected patterns (chaos = duplicates)
- Readings serialize to JSON

**Run**: `cd lambda && python3 tests/test_generator.py`

---

## Phase 2 — Integration Tests (Snowflake)
**Location**: `snowflake/tests/test_integration.sql`

Tests components working together:
- Can Snowflake access the S3 stage? (`LIST @raw_sensor_stage`)
- Does COPY INTO load rows? (count check)
- Are VARIANT fields accessible? (query raw_data:device_id)
- Does the stream detect new rows?

**Run**: Execute in Snowflake worksheet after setup

---

## Phase 4 — Contract Tests (dbt)
**Location**: `dbt/iot_pipeline/models/staging/_staging.yml`

Tests that staging models produce expected schema:
- Column exists and is correct type
- Not-null on required fields (reading_id, device_id, reading_ts)
- Unique constraints (reading_id should be unique in staging)
- Accepted values (device_type in ['Type_A', 'Type_B', 'Type_C'])

**Run**: `dbt test --select staging`

Example:
```yaml
models:
  - name: stg_sensor_readings
    columns:
      - name: reading_id
        tests:
          - not_null
          - unique
      - name: device_id
        tests:
          - not_null
          - relationships:
              to: ref('device_registry')
              field: device_id
```

---

## Phase 4 — Data Quality Tests (dbt_expectations)
**Location**: `dbt/iot_pipeline/models/staging/_staging.yml`

Tests business rules using dbt_expectations package:
- Temperature between -20 and 60
- Humidity between 10 and 95
- Battery between 0 and 100
- Timestamps not in the future
- GPS coordinates within expected ranges

**Run**: `dbt test --select staging`

Example:
```yaml
- name: temperature
  tests:
    - dbt_expectations.expect_column_values_to_be_between:
        min_value: -20
        max_value: 60
        mostly: 0.95  # Allow 5% out-of-range (error injection)
```

---

## Phase 5 — Regression Tests
**Location**: `dbt/iot_pipeline/macros/test_row_count_anomaly.sql`

Custom dbt generic test that flags unexpected row count changes:
- Compare today's row count vs. 7-day rolling average
- Alert if count drops below 50% or spikes above 200% of average
- Prevents silent data loss or duplication at scale

**Run**: `dbt test --select tag:regression`

---

## Phase 6 — Pipeline Tests
**Location**: Airflow CLI commands

Tests that DAGs are valid and tasks execute correctly:
- DAG validation: `airflow dags test iot_pipeline_dag 2026-03-26`
- Task testing: `airflow tasks test iot_pipeline_dag trigger_lambda 2026-03-26`
- Branching: verify quality check routes to correct path
- SLA: verify alerts fire when SLA is missed

---

## Test Pyramid for Data Engineering

```
         /\
        /  \       Pipeline Tests (few, slow, high confidence)
       /    \      "Does the whole DAG work end-to-end?"
      /------\
     /        \    Regression Tests (moderate)
    /          \   "Did row counts change unexpectedly?"
   /------------\
  /              \  Data Quality + Contract Tests (many)
 /                \ "Is the data valid? Does schema match?"
/------------------\
    Unit Tests      (many, fast, low cost)
    "Do functions work correctly?"
```

More tests at the bottom (cheap, fast), fewer at the top (expensive, slow).
Focus most effort on data quality tests — they catch the most real-world issues.
