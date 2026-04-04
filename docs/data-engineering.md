# Data Engineering — Complete Concepts Guide

Everything a data engineer needs to understand: ETL vs ELT, data architecture patterns, data quality, file formats, orchestration, and interview essentials. Written with real examples from our IoT pipeline.

> **Data Modeling** (Star, Snowflake, Data Vault, OBT) is covered in [data-modeling.md](data-modeling.md).

---

# Part 1: ETL vs ELT

## ETL — Extract, Transform, Load

```
Source → [Transform in flight] → Warehouse
         (Lambda, Spark, Python)
```

### How It Works
1. **Extract** data from source (API, database, file)
2. **Transform** it BEFORE loading (clean, validate, aggregate, type-cast)
3. **Load** the clean, transformed data into the warehouse

### In Our Pipeline (Hypothetical ETL Path)
```python
# Lambda would do ALL this before writing to S3:
def lambda_handler(event, context):
    readings = generate_batch()

    # Transform in Lambda:
    for r in readings:
        r['temperature'] = float(r['temperature'])  # Type casting
        r['reading_ts'] = parse_iso(r['reading_ts']) # Date parsing
        if r['temperature'] > 60 or r['temperature'] < -20:
            r['is_valid'] = False                     # Validation
        r['hour_of_day'] = r['reading_ts'].hour       # Derived fields
        r['cluster_city'] = CLUSTER_MAP[r['device_id']] # Enrichment

    # Write Parquet (typed, compressed, columnar)
    write_parquet(readings, 's3://bucket/clean/...')
```

### Problems With ETL
- **Lambda becomes complex**: validation logic, type casting, enrichment — all in Python
- **Hard to debug**: if a transform is wrong, you need to re-run Lambda + re-load
- **Schema changes require code changes**: add a column → update Lambda → redeploy
- **Can't go back**: original raw data is lost (you only stored the transformed version)
- **Bottleneck**: Lambda has 15-min timeout, 10GB memory limit

### When ETL Makes Sense
- **Sensitive data**: PII must be masked BEFORE it reaches the warehouse (GDPR/HIPAA)
- **Cost reduction**: transform 1TB → 100GB before loading (save on warehouse costs)
- **Legacy systems**: older warehouses (Teradata, Oracle) are bad at transformation
- **Real-time requirements**: transform in Kafka Streams/Flink before loading

---

## ELT — Extract, Load, Transform

```
Source → Warehouse → [Transform in warehouse]
                     (dbt, SQL, Snowflake)
```

### How It Works
1. **Extract** data from source
2. **Load** it RAW into the warehouse (JSON, CSV, as-is)
3. **Transform** it INSIDE the warehouse using SQL (dbt)

### In Our Pipeline (What We Actually Do)
```
Lambda writes raw JSON → S3 → COPY INTO sensor_readings (VARIANT)
                                        ↓
                                    dbt transforms:
                                    stg_sensor_readings (TRY_CAST, parse JSON)
                                    int_readings_deduped (remove duplicates)
                                    int_readings_validated (range checks, z-scores)
                                    fct_hourly_readings (aggregate)
```

### Why ELT Won
- **Raw data preserved forever**: `sensor_readings.raw_data` has the original JSON. If a dbt model is wrong, fix the SQL and re-run. No need to re-extract from source.
- **Warehouse does the heavy lifting**: Snowflake can process billions of rows faster than Lambda ever could
- **Schema changes are SQL changes**: add a column → add a line in the dbt model → `dbt run`
- **Version controlled transforms**: dbt models are SQL files in git. Lambda transforms are code buried in AWS.
- **Separation of concerns**: Lambda just generates data. dbt handles all business logic.

### The Hybrid Approach (Real World)
Most modern pipelines use a mix:

```
Source → [Light ETL] → S3 → [Load Raw] → Warehouse → [Heavy ELT]

Light ETL (in Lambda/producer):           Heavy ELT (in dbt):
  - PII masking                             - Type casting
  - File format conversion (JSON → Parquet) - Deduplication
  - Basic schema validation                 - Business logic
  - Compression                             - Aggregations
                                            - Data quality checks
```

Rule of thumb: **ETL for data protection, ELT for data transformation.**

---

## ETL vs ELT Summary

| Criteria | ETL | ELT |
|----------|-----|-----|
| **Where transforms run** | Outside warehouse (Lambda, Spark, Python) | Inside warehouse (dbt, SQL) |
| **Raw data preserved?** | No (only transformed data loaded) | Yes (raw → staging → marts) |
| **Fix a bug** | Re-extract from source, re-transform, re-load | Fix SQL, `dbt run` |
| **Schema changes** | Code change + deploy | SQL change + `dbt run` |
| **Skills needed** | Python, Spark, cloud services | SQL, dbt |
| **Cost model** | Pay for compute (Lambda, EMR) + warehouse | Pay for warehouse only |
| **Best for** | PII masking, format conversion, real-time | All business logic, analytics |
| **Our pipeline** | Lambda does minimal (just generate JSON) | dbt does everything else |

---

# Part 2: Data Architecture Patterns

## 1. Data Warehouse

### What It Is
A **structured, centralized** repository optimized for analytical queries. Data is cleaned, modeled (Star/Snowflake Schema), and schema-enforced before it's queryable.

```
Sources → ETL/ELT → [Data Warehouse]
                      ├── Structured tables
                      ├── Schema enforced
                      ├── SQL access
                      └── Optimized for analytics
```

### Examples
- **Snowflake** (our project)
- **Google BigQuery**
- **Amazon Redshift**
- **Azure Synapse**
- **Teradata**, **Oracle** (legacy)

### How It Works
```sql
-- Schema-on-write: data must match the table definition
CREATE TABLE sensor_readings (
    reading_id VARCHAR,
    temperature FLOAT,    -- Must be a number
    reading_ts TIMESTAMP  -- Must be a timestamp
);

-- INSERT fails if data doesn't match schema
INSERT INTO sensor_readings VALUES ('abc', 'not_a_number', 'not_a_date');
-- ERROR: invalid data type
```

### Pros
- Fast analytical queries (columnar storage, query optimization)
- Strong governance (schema enforcement, RBAC, audit logs)
- SQL — the universal language of data
- Mature tooling (dbt, Looker, Tableau all designed for warehouses)

### Cons
- Rigid schema — adding a column requires DDL
- Expensive for storing raw/unstructured data
- Not great for ML/data science (they want files, not SQL tables)
- Semi-structured data (JSON, Avro) is second-class

### When to Use
- **Business intelligence and reporting** (dashboards, KPIs)
- When data quality and governance matter
- When most consumers use SQL
- **Our project**: Snowflake is our warehouse

---

## 2. Data Lake

### What It Is
A **cheap, schema-less** storage layer that holds raw data in any format. Files sit in object storage (S3, GCS, ADLS) and are processed by compute engines when needed.

```
Sources → [Data Lake (S3)]
            ├── raw/sensor_data/*.json
            ├── raw/logs/*.csv
            ├── raw/images/*.jpg
            ├── raw/ml_training/*.parquet
            └── No schema enforcement
```

### How It Works
```
# Schema-on-read: data has no predefined structure in storage
# You decide the schema when you READ, not when you WRITE

# Writing to data lake — just dump files:
s3.put_object(Key='raw/sensors/data.json', Body=json.dumps(readings))

# Reading from data lake — define schema at query time:
spark.read.json('s3://bucket/raw/sensors/').select('temperature').show()
# OR
SELECT $1:temperature FROM @s3_stage/raw/sensors/data.json
```

### The Data Swamp Problem
Without governance, data lakes become **data swamps**:
```
s3://company-data-lake/
  ├── johns_test_data/
  ├── marketing_export_final_v2_FINAL.csv
  ├── temp_backup_deleteme/
  ├── raw_data/
  │   ├── 2024/ (no documentation)
  │   └── old_format/ (incompatible with new_format)
  └── who_owns_this/
```

### Pros
- Cheapest storage ($23/TB/month on S3 vs $40+/TB on a warehouse)
- Any format: JSON, CSV, Parquet, Avro, images, video
- Decoupled storage and compute (store once, query with anything)
- Great for ML/data science (they want files, not tables)

### Cons
- No schema enforcement (garbage in, garbage stays)
- No ACID transactions (concurrent writes can corrupt data)
- Query performance varies wildly (depends on file format, partitioning)
- Requires strong governance to avoid data swamp

### When to Use
- Storing raw data cheaply (our S3 bucket with Lambda JSON files)
- ML/AI workloads that need file-based access
- When you have diverse data types (structured + unstructured)
- As the **first layer** before loading into a warehouse

### In Our Pipeline
S3 IS our data lake. Lambda writes raw JSON to S3 → Snowflake reads from S3 via COPY INTO. The S3 layer provides cheap, durable storage. Snowflake provides fast, structured analytics.

---

## 3. Data Lakehouse

### What It Is
**The best of both worlds**: data lake's cheap storage + data warehouse's query performance and ACID transactions. Made possible by **open table formats** (Iceberg, Delta Lake, Hudi) that add structure to files in S3.

```
Sources → [S3 / Object Storage]
            ├── Iceberg/Delta tables (structured, ACID, time travel)
            ├── Raw files (unstructured)
            └── Query with SQL OR files
                   ↕
            [Compute Engine]
            ├── Snowflake
            ├── Spark
            ├── Trino/Presto
            └── DuckDB
```

### The Key Innovation: Open Table Formats

Without table format (plain S3):
```
s3://bucket/readings/
  ├── part-001.parquet
  ├── part-002.parquet
  └── part-003.parquet
  # No schema, no transactions, no time travel
  # If a write fails halfway, you have corrupt data
```

With Iceberg (table format on S3):
```
s3://bucket/readings/
  ├── data/
  │   ├── part-001.parquet
  │   ├── part-002.parquet
  │   └── part-003.parquet
  ├── metadata/
  │   ├── snap-001.avro    ← "Snapshot 1: files [001, 002]"
  │   ├── snap-002.avro    ← "Snapshot 2: files [001, 002, 003]"
  │   └── version-hint     ← "Current version: snap-002"
  └── # ACID transactions, time travel, schema evolution!
```

The metadata layer tracks which files belong to which version. This gives you:
- **ACID transactions**: writes are atomic (all or nothing)
- **Time travel**: `SELECT * FROM readings VERSION AS OF '2026-03-28'`
- **Schema evolution**: add/rename columns without rewriting data
- **Partition evolution**: change partitioning strategy without rewriting

### The 3 Open Table Formats

**Apache Iceberg** (most popular, our project uses it):
- Created by Netflix, now Apache project
- Best multi-engine support (Snowflake, Spark, Trino, Flink, DuckDB)
- Hidden partitioning (users don't need to know partition columns)
- Snowflake has native Iceberg table support

**Delta Lake** (Databricks ecosystem):
- Created by Databricks
- Best integration with Spark/Databricks
- Change Data Feed (CDC streaming)
- Most mature for streaming + batch unified processing

**Apache Hudi** (Uber ecosystem):
- Created by Uber
- Best for upsert-heavy workloads (copy-on-write vs merge-on-read)
- Record-level indexing
- Less widely supported than Iceberg/Delta

### Comparison
| Feature | Iceberg | Delta Lake | Hudi |
|---------|---------|------------|------|
| **Created by** | Netflix | Databricks | Uber |
| **Best with** | Any engine | Spark/Databricks | Spark |
| **Snowflake support** | Native | Via Iceberg | Limited |
| **Time travel** | Yes | Yes | Yes |
| **Schema evolution** | Excellent | Good | Good |
| **Streaming** | Good | Best | Good |
| **Community** | Fastest growing | Largest | Smallest |
| **Pick if** | Multi-engine | Databricks shop | Upsert-heavy |

### In Our Pipeline
We set up Iceberg in `snowflake/07_iceberg.sql`. This lets us expose our mart tables as Iceberg tables on S3 — queryable by Snowflake AND external engines like Spark or DuckDB.

---

## 4. Data Mesh (Zhamak Dehghani, 2019)

### What It Is
Not a technology — it's an **organizational architecture**. Instead of one central data team owning all data, each **domain team** owns their own data as a product.

```
Traditional (Centralized):
  Marketing → ┐
  Sales →     ├→ Central Data Team → Data Warehouse → All Consumers
  IoT →       ┘
  (Bottleneck: central team is overwhelmed)

Data Mesh (Decentralized):
  Marketing Team → Marketing Data Product → ┐
  Sales Team →     Sales Data Product →     ├→ Self-serve platform
  IoT Team →       IoT Data Product →       ┘
  (Each team owns their own data end-to-end)
```

### The 4 Principles

**1. Domain Ownership**
The IoT team doesn't just generate data and throw it over the wall. They own the entire pipeline: generation, quality, modeling, serving.

**2. Data as a Product**
Each domain publishes data with the same rigor as a software product:
- SLA (freshness: "updated every hour")
- Schema contract ("these columns, these types, guaranteed")
- Documentation, quality guarantees, discoverability

**3. Self-Serve Data Platform**
A central platform team provides tools, not data: Snowflake provisioning, dbt templates, Airflow templates, monitoring frameworks.

**4. Federated Computational Governance**
Global standards (naming conventions, PII handling, access control) enforced automatically via CI/CD, not by a central team reviewing every change.

### Data Contracts
```yaml
# contract: iot_sensor_readings
version: 2.0
owner: iot-team@company.com
sla:
  freshness: 60 minutes
  availability: 99.5%
schema:
  - name: reading_id
    type: VARCHAR
    nullable: false
  - name: temperature
    type: FLOAT
    nullable: true
    valid_range: [-20, 60]
quality:
  - null_rate(temperature) < 0.05
  - unique(reading_id)
```

### When to Use / When NOT to Use
- **Use**: Large organizations (100+ engineers), clear domain boundaries, central team is a bottleneck
- **Don't**: Small teams (< 20 engineers), startups (just build a warehouse, iterate fast)

---

## 5. Data Fabric (Gartner)

An **AI-driven integration layer** that sits on top of all data sources and automatically handles discovery, governance, and access. More vendor vision than concrete architecture.

| | Data Mesh | Data Fabric |
|---|---|---|
| **Approach** | Organizational (people + process) | Technological (tooling + automation) |
| **Who owns data?** | Domain teams | Centralized (automated) |
| **Key innovation** | Decentralization | AI/ML-driven integration |
| **Products** | dbt + Airflow + contracts | Informatica, Talend, Atlan, Alation |

---

## Architecture Decision Framework

```
Q1: Structured data for analytics?          → Data Warehouse
Q2: Raw/unstructured (logs, images, ML)?    → Data Lake
Q3: Need both SQL analytics AND file-based? → Data Lakehouse
Q4: Large org with many data domains?       → Data Mesh on top
```

Our pipeline: **Lake** (S3) → **Warehouse** (Snowflake) → **Lakehouse** (Iceberg on S3) → **ELT** (dbt) → **Orchestration** (Airflow)

---

# Part 3: Data Quality & Observability

## Data Quality Dimensions

| Dimension | Question | Our Pipeline Example |
|-----------|----------|---------------------|
| **Completeness** | Is the data all there? | NULL temperature readings (error injection) |
| **Accuracy** | Is the data correct? | Temperature = 999°C is inaccurate |
| **Consistency** | Does it match across systems? | Same device_id in Lambda, S3, and Snowflake |
| **Timeliness** | Is it fresh enough? | Pipeline health view checks minutes since last load |
| **Validity** | Does it meet business rules? | Temperature between -20°C and 60°C |
| **Uniqueness** | Are there duplicates? | int_readings_deduped removes dupes |

### Quality Scoring
Our `fct_data_quality` computes a quality score per batch:
```
quality_score = 100 × (valid_readings / total_readings)
90-100: Good (normal)  |  70-89: Warning (high)  |  < 70: Critical (chaos)
```

### The Quarantine Pattern
Bad data doesn't get deleted — it gets quarantined with rejection reasons for debugging, recovery, metrics, and compliance.

## Data Observability (The 5 Pillars)

| Pillar | What It Monitors | Tool/Approach |
|--------|-----------------|---------------|
| **Freshness** | Is data arriving on time? | Pipeline health view, source freshness in dbt |
| **Volume** | Expected row count? | test_row_count_anomaly macro (7-day avg) |
| **Schema** | Did columns change? | dbt contracts, schema tests |
| **Distribution** | Values in expected ranges? | dbt_expectations, z-score |
| **Lineage** | Where did data come from? | dbt docs, `source_file` column |

---

# Part 4: File Formats

## Size & Performance Comparison

| Format | File Size | Read Speed | Column Pruning | Schema | Human Readable |
|--------|----------|------------|----------------|--------|---------------|
| **CSV** | 150 MB | Slow | No | No | Yes |
| **JSON** | 200 MB | Slow | No | Semi | Yes |
| **Avro** | 80 MB | Medium | No (row-based) | Yes | No |
| **Parquet** | 30 MB | Fast | Yes (columnar) | Yes | No |
| **ORC** | 28 MB | Fast | Yes (columnar) | Yes | No |

### Row-Based vs Columnar
```
ROW-BASED (CSV, JSON, Avro):        COLUMNAR (Parquet, ORC):
┌─────┬──────┬──────┐               ┌─────┬─────┬─────┬─────┐
│ id  │ temp │ hum  │               │ id  │ id  │ id  │ id  │  ← id column
├─────┼──────┼──────┤               ├─────┼─────┼─────┼─────┤
│ 001 │ 23.5 │ 65.2 │               │ 001 │ 002 │ 003 │ 004 │
├─────┼──────┼──────┤               └─────┴─────┴─────┴─────┘
│ 002 │ 24.1 │ 63.8 │               To read only temperature:
└─────┴──────┴──────┘                → Read ONLY the temp column (~33% of data)
To read only temperature:
  → Must scan ALL rows (100% of data)
```

### Format Decision Guide
```
Need to read/edit by hand?         → CSV or JSON
Streaming / message queue?         → Avro (schema registry) or JSON
Analytical queries (SELECT cols)?  → Parquet
Hive/Hadoop ecosystem?             → ORC
Data lake storage?                 → Parquet (default) or Avro (streaming)
```

### Parquet Deep Dive
Parquet organizes data into **row groups** (~128MB each):
- **Predicate pushdown**: Footer stores min/max per column per row group. Query `WHERE temperature > 50` skips row groups where max(temp) < 50.
- **Compression**: Snappy (fast), Zstd (better ratio), Gzip (best ratio)
- **Encoding**: Dictionary for low-cardinality (device_id → integers), Delta for timestamps

Rule: **Avro for transport, Parquet for storage.**

---

# Part 5: Orchestration Patterns

## DAG Design Patterns

| Pattern | Diagram | Use Case |
|---------|---------|----------|
| **Linear** | `extract → load → transform → test → publish` | Simple pipelines (ours) |
| **Fan-Out/Fan-In** | `load → [A,B,C parallel] → combine → publish` | dbt parallel models |
| **Conditional Branch** | `validate → (has_data → dbt) or (no_data → skip)` | Our `@task.branch()` |
| **Sensor-Triggered** | `[wait for S3 file] → load → transform` | Our S3 sensor |
| **Event-Driven** | `EventBridge → Lambda → S3` (independent) | Our architecture |

## Idempotency

The most important pipeline property. Running a task once or 10 times produces the same result:
- `COPY INTO` skips already-loaded files
- dbt incremental with merge upserts on key
- `INSERT` without dedup is NOT idempotent (creates duplicates)

## Backfill Strategies

| Strategy | How | When |
|----------|-----|------|
| **Full refresh** | `dbt run --full-refresh` | Model logic changed fundamentally |
| **Incremental reprocess** | Delete bad data + re-run | Bug in specific date range |
| **COPY INTO FORCE** | `COPY INTO ... FORCE = TRUE` | Re-load specific S3 files |
| **Airflow backfill** | `airflow dags backfill -s START -e END` | Reprocess date range |

---

# Part 6: Interview Essentials

## ACID Properties

| Property | Meaning | Our Example |
|----------|---------|-------------|
| **Atomicity** | All or nothing | COPY INTO rolls back entirely if one file fails |
| **Consistency** | Valid state → valid state | NOT NULL on raw_data enforced |
| **Isolation** | Concurrent queries don't interfere | Snowflake MVCC — writers don't block readers |
| **Durability** | Committed data survives crashes | Snowflake persists after COMMIT |

**Where ACID exists:**
- Snowflake, PostgreSQL: Full ACID
- S3 + Iceberg/Delta: ACID via metadata
- Plain S3: No ACID
- Kafka: Partial (within partition only)

## CAP Theorem
You can only have 2 of 3: **Consistency**, **Availability**, **Partition tolerance**. Snowflake chooses CP. Kafka chooses AP.

## Normalization (1NF → 3NF)

- **1NF**: Atomic values, no repeating groups
- **2NF**: No partial dependencies (every non-key depends on full PK)
- **3NF**: No transitive dependencies (non-key doesn't depend on non-key)
- **Denormalization**: Breaking 3NF for query performance (Star Schema, OBT)

## Partitioning & Clustering

- **Partitioning**: How data is physically split. S3 Hive-style: `year=2026/month=03/day=30/`. Snowflake: auto 16MB micro-partitions.
- **Clustering**: How data is sorted within partitions. `CLUSTER BY (device_id, reading_hour)` for faster scans.

## Window Functions

```sql
-- Rolling average
AVG(temperature) OVER (PARTITION BY device_id ORDER BY reading_ts ROWS 11 PRECEDING)

-- Rank within group
RANK() OVER (PARTITION BY cluster_id ORDER BY avg_temperature DESC)

-- Detect gaps
DATEDIFF(minute, LAG(reading_ts) OVER (PARTITION BY device_id ORDER BY reading_ts), reading_ts)

-- Deduplication
ROW_NUMBER() OVER (PARTITION BY reading_id ORDER BY loaded_at DESC) -- keep row_num = 1
```

## Change Data Capture (CDC)

| Method | How | Tools |
|--------|-----|-------|
| **Timestamp-based** | `WHERE updated_at > last_run` | dbt incremental |
| **Log-based** | Read database transaction log | Debezium, Fivetran |
| **Snapshot comparison** | Compare current vs previous | dbt snapshots (SCD2) |
| **Streams** | Row-level change tracking | Snowflake Streams |

## Data Governance & Cost Optimization

| Concept | Our Implementation |
|---------|-------------------|
| **RBAC** | IOT_LOADER, IOT_TRANSFORMER, IOT_READER roles |
| **Auto-suspend** | `AUTO_SUSPEND = 60` on warehouse |
| **Right-size** | XSMALL warehouse for our workload |
| **Result caching** | Snowflake caches 24h (free) |

---

# Part 7: The Modern Data Stack (2024-2026)

```
┌────────────┐  ┌─────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐
│ Ingestion  │──│ Storage  │──│Transform │──│  Serve  │──│ Observe  │
├────────────┤  ├─────────┤  ├──────────┤  ├─────────┤  ├──────────┤
│ Fivetran   │  │ S3      │  │ dbt      │  │ Looker  │  │ Monte    │
│ Airbyte    │  │ Snowflake│  │ Spark    │  │ Tableau │  │  Carlo   │
│ Kafka      │  │ BigQuery│  │ Polars   │  │Streamlit│  │ dbt tests│
│ Lambda     │  │ Iceberg │  │          │  │ Metabase│  │ Soda     │
└────────────┘  └─────────┘  └──────────┘  └─────────┘  └──────────┘
                    └── Orchestration: Airflow / Dagster / Prefect ──┘
```

### Emerging Trends (2025-2026)
1. **Iceberg everywhere** — vendor lock-in is dying
2. **dbt won** the SQL transform layer
3. **Streaming + batch convergence** — Kafka + Flink + dbt, not either/or
4. **AI in data engineering** — LLMs writing SQL, auto-generating models
5. **Data contracts** — moving from "nice idea" to "required practice"
6. **Semantic layer** — metrics defined once, consumed everywhere
7. **FinOps for data** — cost per pipeline, per query, per user

---

# Part 8: Operational Lessons Learned

## Airflow on Small EC2 (t4g.small, 2GB RAM)

Running Airflow with Cosmos on 2GB causes OOM — the DAG file processor imports dbt-core + all packages (~1GB) every parse cycle.

**Symptoms**: `WARNING - Killing DAGFileProcessorProcess`, DAG deactivated.

**Tuning that helped** (but didn't fully solve):
- `MIN_FILE_PROCESS_INTERVAL: 120`, `PARSING_PROCESSES: 1`
- Cosmos `LoadMode.CUSTOM` (Python parsing, doesn't run dbt)
- `LoadMode.DBT_MANIFEST` (lightest, reads pre-built manifest)

**Real fix**: Upgrade to 4GB RAM or run locally.

## Snowflake Key-Pair Authentication

Snowflake MFA rejects automated connections. Solution: RSA key-pair auth.

```bash
# Generate
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -nocrypt -out rsa_key.p8
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

# Assign to Snowflake user
ALTER USER my_user SET RSA_PUBLIC_KEY='MIIBIjANBgk...';

# Use in dbt profiles.yml
private_key_path: "/path/to/rsa_key.p8"  # instead of password
```

## EventBridge + Lambda (Decoupled Producer)

```
EventBridge (hourly) → Lambda → S3    (runs independently)
Airflow (hourly) → COPY INTO → dbt    (catches up automatically)
```

Producer and consumer are independent. If Airflow is down 6 hours, Lambda keeps writing. When Airflow recovers, `COPY INTO` loads all missed files — idempotent, no duplicates, no backfill needed.

```bash
# Manage EventBridge
aws events put-rule --name iot-fleet-hourly-generate --schedule-expression "rate(1 hour)" --state ENABLED
aws events disable-rule --name iot-fleet-hourly-generate
aws events describe-rule --name iot-fleet-hourly-generate
```
