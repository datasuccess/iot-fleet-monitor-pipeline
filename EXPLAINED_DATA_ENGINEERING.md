# Data Engineering — Complete Concepts Guide

Everything a data engineer needs to understand: data modeling approaches, ETL vs ELT, and data architecture patterns (warehouse, lake, lakehouse, mesh). Written with real examples from our IoT pipeline.

---

# Part 1: Data Modeling Approaches

## 1. Star Schema (Kimball, 1996)

### What It Is
A central **fact table** (events, transactions, measurements) surrounded by **dimension tables** (descriptive attributes). Named because the diagram looks like a star.

```
                 dim_devices
                     │
dim_time ─── fct_hourly_readings ─── dim_location
                     │
                dim_sensor_type
```

### How It Works
- **Fact tables** store measurable events at a specific grain (one row per device per hour)
- **Dimension tables** store descriptive context (device name, cluster, type)
- Facts reference dimensions via foreign keys
- Queries JOIN fact to 1-2 dimensions — never dimension to dimension

### Our Implementation
```sql
-- "Average temperature by cluster" — 1 JOIN
SELECT d.cluster_id, AVG(f.avg_temperature)
FROM fct_hourly_readings f
JOIN dim_devices d ON f.device_id = d.device_id
GROUP BY d.cluster_id;
```

### Key Concepts

**Grain**: The most important decision. "What does one row represent?" Our fact table grain is "one device, one hour." Every column must be true at that grain. You can't put a daily total in an hourly table.

**Fact types:**
- **Additive facts**: Can be summed across any dimension (reading_count, total_anomalies)
- **Semi-additive**: Can be summed across some dimensions (battery_pct — can avg across devices, but not across time)
- **Non-additive**: Can never be summed (temperature — must avg, not sum)

**Dimension types:**
- **Conformed dimensions**: Shared across fact tables (dim_devices used by fct_hourly_readings AND fct_device_health)
- **Degenerate dimensions**: Dimension attributes stored on the fact table (reading_id, source_file) — not worth their own table
- **Junk dimensions**: Low-cardinality flags combined into one dimension (is_anomaly, is_weekend, is_business_hours → dim_flags)
- **Role-playing dimensions**: Same dimension used multiple times (dim_date as order_date AND ship_date)

**SCD (Slowly Changing Dimensions):**
- **Type 0**: Never change (device_id, install_date)
- **Type 1**: Overwrite (just update the row — lose history)
- **Type 2**: Add new row with valid_from/valid_to (full history, what our snapshot does)
- **Type 3**: Add a "previous" column (current_firmware, previous_firmware — limited history)

### When to Use
- **Default choice** for analytics and reporting
- When analysts query with SQL or BI tools
- When you need balance between simplicity and flexibility
- 80% of data warehouses use this

### When NOT to Use
- Real-time streaming (star schema is batch-oriented)
- When you have 50+ source systems with conflicting business keys

---

## 2. Snowflake Schema (Normalized Star)

### What It Is
Star Schema with **normalized dimensions** — dimensions broken into sub-dimensions. Named because the diagram looks like a snowflake (branches off branches).

```
dim_device_type ─── dim_device ─── dim_cluster
                        │
                  fct_readings ─── dim_time
```

### How It Differs From Star
| Star Schema | Snowflake Schema |
|---|---|
| `dim_devices` has device_type, cluster_id, city, timezone all in one table | `dim_device` has FK to `dim_cluster` and FK to `dim_device_type` |
| 1 JOIN to get cluster_city | 2 JOINs: fact → dim_device → dim_cluster |
| "FACTORY_A, New York" repeated on all 10 devices | "New York" stored once in dim_cluster |

### Our Implementation
```sql
-- Same question, 3 JOINs
SELECT c.cluster_city, AVG(f.temperature)
FROM fct_readings_normalized f
JOIN dim_device_normalized d ON f.device_sk = d.device_sk
JOIN dim_cluster c ON d.cluster_sk = c.cluster_sk
GROUP BY c.cluster_city;
```

### Surrogate Keys
Snowflake Schema typically uses **surrogate keys** (integer/hash) instead of business keys:

```sql
-- Star Schema: JOIN on business key (readable)
WHERE f.device_id = 'DEV_001'

-- Snowflake Schema: JOIN on surrogate key (faster, but need to look up)
WHERE f.device_sk = 'a1b2c3d4...'
```

Why? If the source system changes device_id format from "DEV_001" to "DEVICE-001", the surrogate key stays the same. Insulates the warehouse from source changes.

### Time Dimension
The most useful piece borrowed from Snowflake Schema into Star Schema:

```sql
-- Pre-computed time attributes (computed once, queried millions of times)
SELECT * FROM dim_time WHERE hour_ts = '2026-03-30 14:00:00';
-- Returns: is_weekend=false, is_business_hours=true, fiscal_quarter=Q1,
--          day_name=Monday, time_of_day_category=afternoon, ...
```

Without dim_time, you'd compute `CASE WHEN dayofweek(...) IN (0,6) THEN true` on every single query.

### When to Use
- Large dimensions that change frequently (100M+ customer records)
- When storage cost matters (not really in Snowflake)
- When you need rich shared dimensions across many fact tables
- **In practice**: rarely used in pure form. Borrow the good ideas (dim_time, surrogate keys) into Star Schema.

### When NOT to Use
- Small-medium datasets (the extra JOINs aren't worth it)
- When analysts query directly (too many JOINs confuse people)

---

## 3. Data Vault (Dan Linstedt, 2000)

### What It Is
A modeling methodology designed for **enterprise-scale** warehouses with many source systems. Everything is append-only — you never update, only insert.

### The 3 Components

**Hubs** — Business entities (things that exist):
```
hub_device:
  hub_device_hk = hash('DEV_001')     -- Deterministic hash of business key
  device_id = 'DEV_001'                -- The actual business key
  load_ts = '2026-01-15 10:00:00'      -- When we first saw this
  record_source = 'lambda_generator'   -- Which system told us
```
Rules: One row per business key. Never updated. Never deleted. The "phone book" of your warehouse.

**Links** — Relationships between entities:
```
link_device_reading:
  link_hk = hash('DEV_001' + 'abc-123')  -- Hash of both business keys
  hub_device_hk = hash('DEV_001')         -- Points to Hub_Device
  hub_reading_hk = hash('abc-123')        -- Points to Hub_Reading
```
Rules: Represents "Device X produced Reading Y." Immutable — a relationship that happened can't un-happen.

**Satellites** — Descriptive attributes that change over time:
```
sat_device_details:
  Row 1: hub_device_hk=hash('DEV_001'), firmware='v1.0', load_ts=Jan 1
  Row 2: hub_device_hk=hash('DEV_001'), firmware='v1.1', load_ts=Mar 15
  Row 3: hub_device_hk=hash('DEV_001'), firmware='v2.0', load_ts=Jun 1
```
Rules: New row for every change. Latest row = current state. Full history automatic.

### The hashdiff Pattern
```sql
hashdiff = hash(firmware_version || error_profile)

-- Before inserting:
-- 1. Compute hashdiff of incoming data
-- 2. Compare with hashdiff of latest satellite row for this hub
-- 3. If same → nothing changed, skip
-- 4. If different → something changed, insert new row
```
This prevents storing duplicate rows when the source sends the same data repeatedly.

### Why Hash Keys Everywhere?

Imagine 3 systems all have customer data:
- CRM calls it `customer_id = 12345`
- Billing calls it `account_num = 'ACC-12345'`
- Support calls it `ticket_owner = 'cust_12345'`

In Star Schema, you need complex mapping logic to figure out these are the same person.

In Data Vault, each source writes independently:
```
hub_customer from CRM:    hash('12345') → hub_hk = 'abc...'
hub_customer from Billing: hash('ACC-12345') → hub_hk = 'def...'
```
Then a **Same-As Link** resolves: "abc... and def... are the same customer." This can happen later, independently, without blocking any loading.

### Data Vault 2.0 Additions
- **Point-in-Time (PIT) tables**: Pre-joined snapshots for faster querying
- **Bridge tables**: Pre-resolved multi-hop relationships
- **Business Vault**: Derived satellites with business rules (calculated fields)
- **Reference tables**: Lookup data (country codes, currency rates)

### When to Use
- **Enterprise** with 10+ source systems feeding the same entities
- **Regulated industries** (banking, healthcare, government) requiring full audit trails
- When sources change frequently (new systems added/retired)
- When you need **parallel loading** (each Hub/Link/Satellite loads independently)
- Long-term data warehouses (10+ year history)

### When NOT to Use
- Small teams (< 5 data engineers)
- Single source system (our project — Data Vault is overkill)
- When analysts need direct access (they need a mart layer on top)
- Prototyping or startups

---

## 4. One Big Table — OBT

### What It Is
Everything denormalized into a **single wide table**. Every dimension attribute, every computed field, every derived metric — all pre-joined.

```
obt_fleet_readings (35+ columns):
  reading_id, device_id, temperature, humidity, pressure, battery_pct,
  device_name, device_type, cluster_id, base_latitude, install_date,
  threshold_min, threshold_max, is_out_of_range, anomaly_severity,
  battery_status, hour_of_day, day_of_week, is_weekend, is_business_hours,
  reading_hour, reading_date, reading_week, gps_drift_km, ...
```

### Why It Works in Modern Warehouses
```
                     Columnar Storage (Snowflake)
                     ┌──────────────────────────────┐
SELECT cluster_id,   │ cluster_id  │ READS THIS     │
       AVG(temp)     │ temperature │ READS THIS     │
FROM obt             │ humidity    │ (skipped)       │
                     │ pressure    │ (skipped)       │
                     │ device_name │ (skipped)       │
                     │ ... 30 more │ (all skipped)   │
                     └──────────────────────────────┘
```
Snowflake only reads the columns your query touches. The 33 unused columns cost zero at query time. They only cost storage ($23/TB/month — pennies for most datasets).

### The Tradeoff
```
Star Schema: UPDATE dim_devices SET device_name = 'New Name' WHERE device_id = 'DEV_001';
             → 1 row updated

OBT:         UPDATE obt SET device_name = 'New Name' WHERE device_id = 'DEV_001';
             → 50,000 rows updated (every historical reading for that device)
```

### When to Use
- **Final analytics layer** that BI tools query
- Ad-hoc exploration (data scientists in notebooks)
- When query simplicity matters more than update efficiency
- As a **view** on top of Star Schema (best of both worlds):
  ```sql
  CREATE VIEW obt_fleet AS
  SELECT f.*, d.device_name, d.cluster_id, ...
  FROM fct_hourly_readings f
  JOIN dim_devices d ON f.device_id = d.device_id;
  ```

### When NOT to Use
- As the source of truth (use Star Schema for that)
- When dimensions change frequently
- When storage cost is a concern (rare)

---

## 5. Activity Schema (Modern, 2020s)

### What It Is
A newer approach from the analytics engineering community. Models all data as a **stream of activities** with a standard structure.

```
activity_stream:
  activity_id    -- Unique event ID
  entity_id      -- Who did it (device_id, customer_id)
  activity_ts    -- When
  activity_type  -- What happened ('reading', 'alert', 'firmware_update')
  feature_json   -- Flexible VARIANT/JSON payload with details
```

### How It Differs
```sql
-- Traditional: different fact tables for different events
SELECT * FROM fct_readings WHERE ...
SELECT * FROM fct_anomalies WHERE ...
SELECT * FROM fct_device_health WHERE ...

-- Activity Schema: one table, filter by activity_type
SELECT * FROM activity_stream WHERE activity_type = 'reading' AND ...
SELECT * FROM activity_stream WHERE activity_type = 'anomaly' AND ...
```

### Pros
- One table to rule them all — simple data pipeline
- Flexible schema via JSON payload (new event types without schema changes)
- Works well with event-driven architectures and streaming

### Cons
- JSON parsing at query time is slower than typed columns
- Harder to enforce data quality (each activity_type has different expected fields)
- Not widely adopted yet — less tooling support

### When to Use
- Event-heavy systems (user clickstreams, IoT events, microservice logs)
- When new event types appear frequently
- Startups that need flexibility over structure

---

## 6. Wide Events / Entity-Centric (Modern)

### What It Is
Inspired by how observability platforms (Datadog, Honeycomb) store data. Every event is a **wide row** with hundreds of potential columns, most of which are NULL for any given row.

```
wide_events:
  event_id, timestamp, entity_type, entity_id,
  temperature (NULL if not a reading),
  anomaly_type (NULL if not an anomaly),
  alert_severity (NULL if not an alert),
  firmware_old, firmware_new (NULL if not an update),
  ... 100+ sparse columns
```

### Why It Exists
Modern columnar databases (Snowflake, BigQuery, ClickHouse) handle sparse columns efficiently. A NULL column in a columnar store takes almost zero storage. So you can have 200 columns where each row only populates 10 of them.

### When to Use
- Observability/monitoring data
- When you want one table for everything (like OBT but for mixed event types)
- High-volume event streams where JOIN performance matters

---

## Model Comparison Matrix

| Criteria | Star | Snowflake | Data Vault | OBT | Activity |
|----------|------|-----------|------------|-----|----------|
| **Complexity** | Low | Medium | High | Lowest | Low |
| **JOINs per query** | 1-3 | 3-5 | 3-5 | 0 | 0-1 |
| **History tracking** | Manual SCD | Manual SCD | Automatic | None | Append |
| **Update cost** | Low | Lowest | None (append) | Highest | None |
| **Query speed** | Fast | Medium | Slow (need marts) | Fastest | Fast |
| **Multi-source** | OK | OK | Excellent | Poor | OK |
| **Analyst-friendly** | Yes | Somewhat | No | Most | Somewhat |
| **Best for** | Analytics | Large DW | Enterprise | BI layer | Events |
| **Team size** | Any | Medium+ | Large | Any | Any |

---

# Part 2: ETL vs ELT

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

### Your Intuition Was Right
> "etl we need to spend more time on lambda functions which is not the good idea"

Exactly. Putting transform logic in Lambda means:
- Data engineers need Python + AWS + deployment skills to change business rules
- Transform logic is scattered across Lambda functions instead of centralized in dbt
- You can't test transforms locally (need to invoke Lambda)
- No lineage graph (dbt gives you `dbt docs generate` with a visual DAG)

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

# Part 3: Data Architecture Patterns

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

Nobody knows what's there, what format it's in, whether it's current, or who put it there.

### Examples
- **Amazon S3** + **Athena** (query S3 with SQL)
- **Google Cloud Storage** + **BigQuery external tables**
- **Azure Data Lake Storage** + **Databricks**
- **HDFS** + **Hive/Spark** (legacy Hadoop)

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

### Examples
- **Databricks Lakehouse** (Delta Lake + Spark + Unity Catalog)
- **Snowflake with Iceberg** (what our `07_iceberg.sql` sets up)
- **AWS Lake Formation** + **Iceberg** + **Athena**
- **Tabular** (Iceberg-native, founded by Iceberg creators, acquired by Databricks)

### When to Use
- When you need warehouse performance but don't want vendor lock-in
- When the same data serves both SQL analysts AND ML engineers
- When you need time travel and schema evolution on S3
- When you want to query from multiple engines (Snowflake + Spark + DuckDB)

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

In our project, this would mean:
- IoT team owns Lambda + S3 + the dbt models for sensor data
- Fleet operations team owns the anomaly detection models
- Executive team owns the fleet overview reports

**2. Data as a Product**
Each domain publishes data with the same rigor as a software product:
- SLA (freshness: "updated every hour")
- Schema contract ("these columns, these types, guaranteed")
- Documentation (what each field means)
- Quality guarantees ("< 1% null rate on temperature")
- Discoverability (listed in a data catalog)

**3. Self-Serve Data Platform**
A central platform team provides tools, not data:
- Snowflake account + warehouse provisioning
- dbt project templates
- Airflow DAG templates
- Data quality frameworks
- Monitoring dashboards

Domain teams use these tools to build their own pipelines.

**4. Federated Computational Governance**
Global standards (naming conventions, PII handling, access control) enforced automatically, not by a central team reviewing every change:
- Automated schema validation
- PII detection in CI/CD
- Standard data quality tests
- Central catalog + lineage

### Data Contracts
The practical tool that enables Data Mesh:

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
  - name: device_id
    type: VARCHAR
    nullable: false
quality:
  - null_rate(temperature) < 0.05
  - unique(reading_id)
```

If the IoT team changes the schema without updating the contract, downstream consumers (dashboards, ML models) break — and the contract violation is caught in CI/CD before it reaches production.

### When to Use
- **Large organizations** (100+ engineers, multiple data domains)
- When the central data team is a bottleneck
- When domains have clear ownership boundaries
- When data quality issues are caused by "nobody owns this data"

### When NOT to Use
- Small teams (< 20 engineers) — the overhead isn't worth it
- When domains aren't clearly defined
- Startups (just build a warehouse, iterate fast)

### The Reality
Most companies that "adopt Data Mesh" actually adopt **2 of the 4 principles**: domain ownership + data as a product. The full self-serve platform and federated governance are hard to build and maintain.

---

## 5. Data Fabric (Gartner)

### What It Is
An **AI-driven integration layer** that sits on top of all your data sources and automatically handles discovery, governance, and access. More of a vendor vision than a concrete architecture.

```
┌─────────────────────────────────────────────────┐
│              Data Fabric Layer                    │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
│  │ Knowledge │ │ Auto     │ │ Policy           │ │
│  │ Graph     │ │ Discovery│ │ Engine           │ │
│  └──────────┘ └──────────┘ └──────────────────┘ │
└────────┬──────────────┬──────────────┬──────────┘
         │              │              │
    ┌────┴────┐   ┌─────┴─────┐  ┌────┴────┐
    │Snowflake│   │ S3 Lake   │  │ MongoDB │
    └─────────┘   └───────────┘  └─────────┘
```

### Key Idea
Instead of manually building integrations between systems, the fabric **automatically**:
- Discovers data across all sources
- Maps relationships (knowledge graph)
- Enforces governance (PII detection, access control)
- Recommends how to combine data from different sources

### Data Mesh vs Data Fabric

| | Data Mesh | Data Fabric |
|---|---|---|
| **Approach** | Organizational (people + process) | Technological (tooling + automation) |
| **Who owns data?** | Domain teams | Centralized (automated) |
| **Key innovation** | Decentralization | AI/ML-driven integration |
| **Maturity** | Emerging (some adoption) | Mostly vendor marketing |
| **Products** | dbt + Airflow + contracts | Informatica, Talend, Atlan, Alation |

### The Honest Take
Data Fabric is more of a **product category** pushed by vendors (Informatica, Talend) than an architecture you'd build from scratch. The useful ideas (knowledge graphs, automated discovery, active metadata) are being adopted piece by piece into existing architectures.

---

## Architecture Decision Framework

```
┌─────────────────────────────────────────────────────────────────┐
│ "Where should I put my data?"                                    │
│                                                                  │
│ Q1: Is it structured data for analytics?                         │
│   YES → Data Warehouse (Snowflake, BigQuery)                     │
│   NO  → Q2                                                       │
│                                                                  │
│ Q2: Is it raw/unstructured (logs, images, ML training data)?     │
│   YES → Data Lake (S3 + Athena/Spark)                            │
│   NO  → Q3                                                       │
│                                                                  │
│ Q3: Do you need both SQL analytics AND file-based ML access?     │
│   YES → Data Lakehouse (Iceberg/Delta on S3 + Snowflake/Spark)   │
│   NO  → Warehouse is probably fine                                │
│                                                                  │
│ Q4: Is your organization large with many data domains?           │
│   YES → Consider Data Mesh principles on top of your choice      │
│   NO  → Centralized team + warehouse/lakehouse is fine           │
└─────────────────────────────────────────────────────────────────┘
```

### The Modern Stack (2024-2026)

Most companies end up here:

```
Sources → S3 (Data Lake) → Snowflake/BigQuery (Warehouse) → dbt (Transform) → BI Tools
                ↓
          Iceberg tables (Lakehouse layer for ML/Spark access)
```

This is exactly what our pipeline does:
- **Lake**: S3 stores raw JSON from Lambda
- **Warehouse**: Snowflake stores structured tables
- **Lakehouse**: Iceberg tables (07_iceberg.sql) expose marts to external engines
- **Transform**: dbt handles all business logic (ELT)
- **Orchestration**: Airflow coordinates everything

---

# Part 4: Data Quality & Observability

## Data Quality Dimensions

Every piece of data can be evaluated on 6 dimensions. These are industry-standard (defined by DAMA International):

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

90-100: Good (normal operation)
70-89:  Warning (high error profile)
< 70:   Critical (chaos error profile)
```

### The Quarantine Pattern
Bad data doesn't get deleted — it gets quarantined:

```
stg_sensor_readings (all data)
  → int_readings_validated
      → validation_error_count = 0 → int_readings_enriched → marts (clean data)
      → validation_error_count > 0 → int_quarantined_readings (bad data + reasons)
```

Why keep bad data?
- **Debugging**: see exactly what went wrong
- **Recovery**: fix the validation rule, re-process quarantined records
- **Metrics**: track error rates over time
- **Compliance**: prove you didn't silently drop data

---

## Data Observability (The 5 Pillars)

Data observability is like application monitoring (Datadog, New Relic) but for data pipelines:

| Pillar | What It Monitors | Tool/Approach |
|--------|-----------------|---------------|
| **Freshness** | Is data arriving on time? | Pipeline health view, source freshness in dbt |
| **Volume** | Are we getting the expected row count? | test_row_count_anomaly macro (7-day avg) |
| **Schema** | Did columns change? | dbt contracts, schema tests |
| **Distribution** | Are values in expected ranges? | dbt_expectations (between tests), z-score |
| **Lineage** | Where did data come from? Where does it go? | dbt docs, `source_file` column |

### Observability Tools in the Market
- **Monte Carlo**: Automated anomaly detection on data (the "Datadog of data")
- **Elementary**: Open-source dbt-native observability
- **Great Expectations**: Python-based data validation
- **Soda**: Data quality checks as YAML
- **dbt tests + dbt_expectations**: What we use (free, built into dbt)

---

# Part 5: File Formats

## Why File Format Matters

The same 1 million sensor readings stored in different formats:

| Format | File Size | Read Speed | Column Pruning | Schema | Human Readable |
|--------|----------|------------|----------------|--------|---------------|
| **CSV** | 150 MB | Slow | No (reads all) | No | Yes |
| **JSON** | 200 MB | Slow | No (reads all) | Semi | Yes |
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
│ 002 │ 24.1 │ 63.8 │               ┌─────┬─────┬─────┬─────┐
├─────┼──────┼──────┤               │temp │temp │temp │temp │  ← temp column
│ 003 │ 22.9 │ 67.0 │               ├─────┼─────┼─────┼─────┤
└─────┴──────┴──────┘               │23.5 │24.1 │22.9 │25.0 │
                                    └─────┴─────┴─────┴─────┘
To read only temperature:            To read only temperature:
  → Must scan ALL rows               → Read ONLY the temp column
  → Read 100% of data                → Read ~33% of data
```

### Format Decision Guide

```
Need to read/edit by hand?         → CSV or JSON
Streaming / message queue?         → Avro (schema registry) or JSON
Analytical queries (SELECT cols)?  → Parquet
Hive/Hadoop ecosystem?             → ORC
Machine learning training?         → Parquet
Data lake storage?                 → Parquet (default) or Avro (streaming)
```

### Parquet Deep Dive

Parquet organizes data into **row groups** (default ~128MB each):

```
parquet_file.parquet
├── Row Group 0 (rows 0-999,999)
│   ├── Column: device_id  [dictionary encoded, snappy compressed]
│   ├── Column: temperature [plain encoded, snappy compressed]
│   ├── Column: humidity    [plain encoded, snappy compressed]
│   └── Column: reading_ts  [delta encoded, snappy compressed]
├── Row Group 1 (rows 1M-1.99M)
│   └── ...
└── Footer
    ├── Schema (column names, types)
    ├── Row group metadata (min/max per column per row group)
    └── File statistics
```

**Predicate pushdown**: The footer stores min/max per column per row group. When you query `WHERE temperature > 50`, the engine reads the footer first and **skips entire row groups** where max(temperature) < 50. Reads 5% of the file instead of 100%.

**Compression**: Parquet supports Snappy (fast, moderate ratio), Zstd (slower, better ratio), Gzip (slowest, best ratio). Default is Snappy — good balance.

**Encoding**: Dictionary encoding for low-cardinality columns (device_id has only 50 values → stored as integers 0-49 + a dictionary). Delta encoding for timestamps (store differences instead of absolute values).

### Avro vs Parquet

| | Avro | Parquet |
|---|---|---|
| **Layout** | Row-based | Columnar |
| **Best for** | Writing (streaming) | Reading (analytics) |
| **Schema** | Embedded in file | Embedded in footer |
| **Schema evolution** | Excellent (reader/writer schemas) | Good |
| **Splittable** | Yes | Yes |
| **Kafka** | Default format | Not common |
| **Snowflake** | Supported | Preferred |

Rule: **Avro for transport, Parquet for storage.**

---

# Part 6: Orchestration Patterns

## DAG Design Patterns

### 1. Linear Pipeline
```
extract → load → transform → test → publish
```
Simple, easy to debug. Our pipeline is mostly this.

### 2. Fan-Out / Fan-In
```
extract → load → ┬─ transform_a ─┐
                 ├─ transform_b ─┤→ combine → publish
                 └─ transform_c ─┘
```
Parallel transforms that merge. dbt does this automatically (models with no dependencies run in parallel).

### 3. Conditional Branching
```
load → validate → ┬─ (has_data) → dbt → publish
                   └─ (no_data) → skip → log
```
Our `@task.branch()` pattern. Route based on data quality or volume.

### 4. Sensor-Triggered
```
[wait for S3 file] → load → transform
```
Don't run on a schedule — wait for data to arrive. Our custom S3 sensor does this.

### 5. Event-Driven (Decoupled)
```
Producer: EventBridge → Lambda → S3 (runs independently)
Consumer: Airflow → COPY INTO → dbt (runs on schedule, catches up)
```
Our current architecture. Producer and consumer are completely independent.

## Idempotency

The most important property of a data pipeline. A task is **idempotent** if running it once or running it 10 times produces the same result.

```sql
-- IDEMPOTENT: Snowflake COPY INTO skips already-loaded files
COPY INTO sensor_readings FROM @stage;
-- Run once: loads 3 files
-- Run again: loads 0 files (already loaded)
-- Result: same data either way ✓

-- IDEMPOTENT: dbt incremental with merge strategy
-- Processes new rows, updates existing rows with same key
-- Run once or twice: same result ✓

-- NOT IDEMPOTENT: INSERT without dedup
INSERT INTO readings SELECT * FROM staging;
-- Run once: 100 rows
-- Run again: 200 rows (duplicates!) ✗
```

Why it matters: Airflow tasks can retry on failure. If a task ran halfway and retries, idempotency ensures you don't get duplicates.

## Backfill Strategies

When you need to reprocess historical data:

| Strategy | How | When |
|----------|-----|------|
| **Full refresh** | `dbt run --full-refresh` | Model logic changed fundamentally |
| **Incremental reprocess** | Delete bad data + re-run | Bug in a specific date range |
| **COPY INTO with FORCE** | `COPY INTO ... FORCE = TRUE` | Need to re-load specific S3 files |
| **Airflow backfill** | `airflow dags backfill -s START -e END` | Reprocess specific date range |
| **catchup=True** | Airflow replays missed runs | Only if each run is date-specific |

Our approach: `catchup=False` + idempotent COPY INTO. Recovery is automatic — no backfill needed for missed runs.

---

# Part 7: Data Engineering Interview Essentials

## Concepts You Must Know

### 1. ACID Properties (Databases & Transactions)
- **Atomicity**: All or nothing. A transaction fully completes or fully rolls back.
- **Consistency**: Data always moves from one valid state to another.
- **Isolation**: Concurrent transactions don't interfere with each other.
- **Durability**: Once committed, data survives crashes.

Snowflake provides ACID. Plain S3 files don't (that's why Iceberg/Delta add it).

### 2. CAP Theorem (Distributed Systems)
You can only have 2 of 3:
- **Consistency**: Every read sees the latest write
- **Availability**: Every request gets a response
- **Partition tolerance**: System works despite network splits

Snowflake chooses CP (consistency + partition tolerance). Kafka chooses AP (availability + partition tolerance — consumers may read slightly stale data).

### 3. Normalization (1NF through 3NF)

**1NF**: No repeating groups, atomic values
```
BAD:  device_id | sensors: "temp,humidity,pressure"
GOOD: device_id | sensor_type | value (one row per sensor)
```

**2NF**: 1NF + no partial dependencies (every non-key column depends on the FULL primary key)
```
BAD:  (device_id, reading_ts) | temperature | device_name
      device_name depends only on device_id, not on (device_id, reading_ts)
GOOD: Split into readings(device_id, reading_ts, temperature) + devices(device_id, device_name)
```

**3NF**: 2NF + no transitive dependencies (non-key columns don't depend on other non-key columns)
```
BAD:  device_id | cluster_id | cluster_city
      cluster_city depends on cluster_id, not directly on device_id
GOOD: Split into devices(device_id, cluster_id) + clusters(cluster_id, cluster_city)
      This is exactly what our Snowflake Schema does!
```

**Denormalization**: Deliberately breaking 3NF for query performance (Star Schema, OBT).

### 4. Partitioning & Clustering

**Partitioning** (how data is physically split):
```
S3 partitioning (our Lambda):
  sensor_readings/year=2026/month=03/day=30/hour=14/batch.json

  Query: WHERE year=2026 AND month=03
  → Only scans March 2026 files, skips everything else

Snowflake micro-partitions:
  Snowflake auto-partitions into 16MB compressed micro-partitions
  Query optimizer prunes partitions using min/max metadata
```

**Clustering** (how data is sorted within partitions):
```sql
-- Snowflake clustering key
ALTER TABLE fct_hourly_readings CLUSTER BY (device_id, reading_hour);
-- Now queries filtering by device_id + reading_hour scan fewer micro-partitions
```

### 5. Window Functions (SQL Interview Favorite)

```sql
-- Running average (last 12 readings)
AVG(temperature) OVER (
    PARTITION BY device_id
    ORDER BY reading_ts
    ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
) AS rolling_avg_temp

-- Rank devices by temperature within each cluster
RANK() OVER (
    PARTITION BY cluster_id
    ORDER BY avg_temperature DESC
) AS temp_rank

-- Detect gaps (minutes between readings)
DATEDIFF(minute,
    LAG(reading_ts) OVER (PARTITION BY device_id ORDER BY reading_ts),
    reading_ts
) AS minutes_since_last_reading

-- Deduplication (our int_readings_deduped pattern)
ROW_NUMBER() OVER (
    PARTITION BY reading_id
    ORDER BY loaded_at DESC
) AS row_num
-- WHERE row_num = 1 → keeps latest version of each reading
```

### 6. Change Data Capture (CDC)

How to track changes in source systems:

| Method | How | Tools |
|--------|-----|-------|
| **Timestamp-based** | `WHERE updated_at > last_run` | dbt incremental |
| **Log-based** | Read database transaction log | Debezium, Fivetran, AWS DMS |
| **Trigger-based** | Database triggers write to changelog | Legacy, avoid |
| **Snapshot comparison** | Compare current vs previous full snapshot | dbt snapshots (SCD2) |
| **Streams** | Snowflake tracks row-level changes | Snowflake Streams (our 05_streams.sql) |

Our pipeline uses:
- **Timestamp-based CDC** in dbt incremental models (`WHERE loaded_at > last_run`)
- **Snowflake Streams** for tracking raw table changes
- **dbt Snapshots** for SCD Type 2 on device metadata

### 7. Data Governance & Security

| Concept | What | Our Implementation |
|---------|------|-------------------|
| **RBAC** | Role-based access control | IOT_LOADER (write raw), IOT_TRANSFORMER (read/write all) |
| **Column masking** | Hide sensitive columns from certain roles | Not implemented (no PII in sensor data) |
| **Row access policy** | Different roles see different rows | Could add: analyst sees only their cluster |
| **Data classification** | Tag columns as PII, sensitive, public | Snowflake has built-in classification |
| **Encryption** | At-rest and in-transit | S3 SSE + Snowflake automatic |
| **Audit logging** | Who queried what, when | Snowflake QUERY_HISTORY |

### 8. Cost Optimization

| Strategy | Impact | Our Implementation |
|----------|--------|-------------------|
| **Auto-suspend warehouse** | High | `ALTER WAREHOUSE SET AUTO_SUSPEND = 60` |
| **Right-size warehouse** | High | XSMALL for our workload |
| **Clustering keys** | Medium | On large fact tables |
| **Materialized views** | Medium | For expensive repeated queries |
| **Transient tables** | Low | Skip Fail-Safe for staging tables |
| **Result caching** | Free | Snowflake caches query results for 24h |
| **Parquet over JSON** | Medium | Columnar = less data scanned |

---

# Part 8: The Modern Data Stack (2024-2026)

## The Standard Toolchain

```
┌─────────────┐     ┌─────────┐     ┌───────────┐     ┌─────────┐     ┌──────────┐
│  Ingestion   │────│ Storage  │────│ Transform  │────│  Serve   │────│ Observe  │
├─────────────┤     ├─────────┤     ├───────────┤     ├─────────┤     ├──────────┤
│ Fivetran     │     │ S3       │     │ dbt        │     │ Looker   │     │ Monte    │
│ Airbyte      │     │ GCS      │     │ Spark      │     │ Tableau  │     │  Carlo   │
│ Debezium     │     │ Snowflake│     │ Snowflake  │     │ Streamlit│     │ Elementry│
│ Kafka        │     │ BigQuery │     │ Polars     │     │ Metabase │     │ dbt tests│
│ Custom       │     │ Databricks│    │            │     │ Sigma    │     │ Soda     │
│  (Lambda)    │     │ Iceberg  │     │            │     │ Hex      │     │          │
└─────────────┘     └─────────┘     └───────────┘     └─────────┘     └──────────┘
                         │                                                    │
                    ┌────┴────────────────────────────────────────────────────┴────┐
                    │                    Orchestration                              │
                    │            Airflow / Dagster / Prefect / Mage                 │
                    └─────────────────────────────────────────────────────────────┘
```

### Tool Categories

**Ingestion** (getting data into the platform):
- **Fivetran / Airbyte**: Managed connectors (300+ sources, no code)
- **Debezium**: Open-source CDC from databases
- **Kafka / Kafka Connect**: Streaming ingestion
- **Custom scripts**: Lambda functions, Python scripts (what we built)

**Storage** (where data lives):
- **Snowflake / BigQuery / Redshift**: Cloud warehouses
- **S3 / GCS / ADLS**: Object storage (data lake)
- **Iceberg / Delta / Hudi**: Table formats (lakehouse)
- **Databricks**: Unified analytics platform (lake + warehouse)

**Transform** (business logic):
- **dbt**: SQL-based transforms, industry standard (what we use)
- **Spark**: Distributed processing for large scale
- **Polars**: Fast DataFrame library (Rust-based, Python API)
- **SQLMesh**: dbt alternative with virtual environments

**Serve** (how consumers access data):
- **Looker / Tableau / Power BI**: Enterprise BI
- **Streamlit**: Python dashboards (what we use)
- **Metabase**: Open-source BI
- **Sigma / Hex**: Cloud-native analytics notebooks

**Observe** (monitoring data quality):
- **Monte Carlo**: Automated data observability
- **Elementary**: dbt-native observability (open-source)
- **Soda**: Data quality as YAML
- **dbt tests**: Built-in (what we use)

**Orchestrate** (scheduling and dependencies):
- **Airflow**: Most widely used (what we use)
- **Dagster**: Software-defined assets, type-safe
- **Prefect**: Pythonic, easy to start
- **Mage**: Visual pipeline builder

### Emerging Trends (2025-2026)

1. **Iceberg everywhere**: Snowflake, BigQuery, Databricks, Athena all support Iceberg natively. Vendor lock-in is dying.

2. **dbt + Snowflake/BigQuery**: The SQL transform layer is settled. dbt won.

3. **Streaming + batch convergence**: Kafka + Flink for real-time, dbt for batch, same warehouse. Not either/or.

4. **AI in data engineering**: LLMs writing SQL, auto-generating dbt models, automated anomaly detection. Still early but accelerating.

5. **Data contracts**: Formal agreements between producers and consumers. Moving from "nice idea" to "required practice."

6. **Semantic layer**: Metrics defined once (in dbt Metrics or Cube), consumed everywhere. No more "my dashboard says X but yours says Y."

7. **Cost awareness**: FinOps for data. Teams tracking cost per pipeline, per query, per user. Snowflake credit monitoring (our `10_cost_monitoring.sql`).

---

# Part 9: Remaining Project Phases

## Phase 10: ETL vs ELT (No Implementation Needed)
- ✅ Covered above — understand the tradeoffs
- Our pipeline is ELT: Lambda (minimal) → S3 (raw) → Snowflake → dbt (transforms)
- The hybrid approach: light validation in Lambda, heavy transforms in dbt

## Phase 11: Schema Evolution & Live Changes
- [ ] Add `co2_level` sensor field to Lambda — simulate firmware update
- [ ] Handle new field in dbt without breaking existing models
- [ ] Backfill strategy for historical data missing the new field
- [ ] `ALTER TABLE` migration scripts

## Phase 12: Streamlit Dashboards
- [x] Fleet Monitor, Data Quality, Anomaly Explorer, Pipeline Admin (Snowflake-native)

## Phase 13: Real-World Scenarios
- [ ] Incident simulation — break something, document debugging
- [ ] Data backfill — re-process 3 days after discovering a bug
- [ ] RBAC — create read-only analyst role
- [ ] CI/CD — GitHub Actions for dbt test on PR

## Phase 14: Data Formats & Processing
- [ ] Parquet vs JSON vs CSV vs Avro — hands-on comparison
- [ ] Iceberg deep dive — time travel, schema evolution, partition evolution
- [ ] Pandas vs Polars — benchmark on our dataset
- [ ] DuckDB — local analytical queries on Parquet files

## Phase 15: Kafka & Streaming (NEW)
- [ ] Kafka + Zookeeper on Docker (EC2)
- [ ] Python producer simulating real-time sensor events
- [ ] Python consumer writing to Snowflake
- [ ] Compare: batch (hourly COPY INTO) vs streaming (seconds)
- [ ] Kafka concepts: topics, partitions, consumer groups, offsets
- [ ] `EXPLAINED_STREAMING.md` — batch vs streaming, Kafka vs alternatives
