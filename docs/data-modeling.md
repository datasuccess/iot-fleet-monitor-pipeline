# Data Modeling Deep Dive — 4 Approaches Compared

We modeled the same IoT sensor data using 4 different approaches. All run on the same source data (`int_readings_enriched` or `stg_sensor_readings`). This lets you compare them side-by-side.

---

## 1. Star Schema (Our Default — `models/marts/`)

```
                    ┌──────────────┐
                    │  dim_devices  │
                    └──────┬───────┘
                           │
┌────────────────┐   ┌─────┴──────────────┐   ┌──────────────────┐
│ fct_anomalies  │───│ fct_hourly_readings │───│ fct_device_health│
└────────────────┘   └────────────────────┘   └──────────────────┘
                           │
                    ┌──────┴───────┐
                    │ rpt_fleet    │
                    └──────────────┘
```

### How It Works
- **One central fact table** (`fct_hourly_readings`) with numeric measures
- **One dimension table** (`dim_devices`) with descriptive attributes
- Fact JOINs to dimension on `device_id` — **one hop**

### The SQL
```sql
-- Average temp per cluster, last 24h — Star Schema
SELECT d.cluster_id, AVG(f.avg_temperature) AS avg_temp
FROM marts.fct_hourly_readings f
JOIN marts.dim_devices d ON f.device_id = d.device_id
WHERE f.reading_hour >= DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY d.cluster_id;
-- 1 JOIN, simple
```

### Pros
- Simple to understand and query (1 JOIN per dimension)
- Fast queries in Snowflake (optimized for star schema scans)
- Industry standard — every analyst knows this pattern
- Best balance of simplicity vs flexibility

### Cons
- Dimension updates require updating one table (manageable)
- Some redundancy in dimensions (cluster info repeated per device)
- Not ideal for tracking full history of changes (need SCD Type 2)

### When to Use
- **Most analytics use cases** — this is the default choice
- When analysts query directly with SQL or BI tools
- When query simplicity matters more than storage optimization

---

## 2. Snowflake Schema (`models/snowflake_schema/`)

```
┌──────────────┐     ┌────────────────────┐     ┌────────────────┐
│ dim_cluster   │────│ dim_device_normalized│────│ dim_device_type │
└──────────────┘     └─────────┬──────────┘     └────────────────┘
                               │
                    ┌──────────┴──────────┐
                    │fct_readings_normal.  │
                    └──────────┬──────────┘
                               │
                        ┌──────┴──────┐
                        │  dim_time    │
                        └─────────────┘
```

### How It Works
- **Fact table uses surrogate keys** (hashes) instead of business keys
- **Dimensions are normalized**: `dim_devices` breaks into `dim_device_normalized` + `dim_cluster` + `dim_device_type`
- **Separate time dimension** with pre-computed attributes
- Queries need **2-3 JOINs** to reach the same info as Star Schema

### Our Models
- `dim_cluster` — cluster_id, city, timezone, category (5 rows)
- `dim_device_type` — Type_A/B/C, accuracy tier, calibration interval, cost (3 rows)
- `dim_device_normalized` — device attributes + FK to cluster_sk + FK to device_type_sk (50 rows)
- `dim_time` — hourly grain, 2 years, pre-computed is_weekend/business_hours etc. (~17K rows)
- `fct_readings_normalized` — measures + FK to device_sk + FK to time_sk

### The SQL
```sql
-- Average temp per cluster, last 24h — Snowflake Schema
SELECT c.cluster_city, AVG(f.temperature) AS avg_temp
FROM snowflake_schema.fct_readings_normalized f
JOIN snowflake_schema.dim_device_normalized d ON f.device_sk = d.device_sk
JOIN snowflake_schema.dim_cluster c ON d.cluster_sk = c.cluster_sk
JOIN snowflake_schema.dim_time t ON f.time_sk = t.time_sk
WHERE t.hour_ts >= DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY c.cluster_city;
-- 3 JOINs! More complex, but gives access to richer attributes
```

### Pros
- Zero redundancy — cluster info stored once (5 rows), not repeated per device
- Clean updates — change cluster timezone → update 1 row
- Rich pre-computed dimensions (time dimension with fiscal quarters, holidays, etc.)
- Surrogate keys = smaller fact table (hash vs varchar)

### Cons
- More JOINs = more complex queries
- Slower in analytical databases (more JOINs to resolve)
- Harder for analysts to discover and understand the model
- Over-engineering for small datasets

### When to Use
- **Large dimensions that change frequently** (e.g., customer dim with 10M rows)
- When storage cost matters (rare in Snowflake)
- When you need a shared time dimension across many fact tables
- OLTP-adjacent systems where normalization prevents update anomalies

---

## 3. Data Vault (`models/data_vault/`)

```
┌──────────────┐     ┌──────────────────────┐     ┌───────────────────┐
│  hub_device   │────│ link_device_reading   │────│ hub_sensor_reading │
└──────┬───────┘     └──────────────────────┘     └────────┬──────────┘
       │                                                    │
┌──────┴───────────┐                              ┌────────┴──────────┐
│sat_device_details│                              │sat_reading_metrics│
└──────────────────┘                              └───────────────────┘
```

### How It Works
- **Hubs**: One row per unique business key (device_id, reading_id). Never changes.
- **Links**: Relationships between hubs ("Device X produced Reading Y"). Never changes.
- **Satellites**: Descriptive attributes that change over time. New row per change (like SCD Type 2, but automatic).
- Everything uses **hash keys** for consistency and parallel loading.

### Our Models
- `hub_device` — 50 rows (one per device, forever)
- `hub_sensor_reading` — one row per unique reading_id
- `link_device_reading` — connects devices to their readings
- `sat_device_details` — firmware_version, error_profile changes over time
- `sat_reading_metrics` — actual sensor values (temperature, humidity, etc.)

### The SQL
```sql
-- Average temp per cluster, last 24h — Data Vault
SELECT dr.cluster_id, AVG(rm.temperature) AS avg_temp
FROM data_vault.sat_reading_metrics rm
JOIN data_vault.link_device_reading l ON rm.hub_reading_hk = l.hub_reading_hk
JOIN data_vault.hub_device hd ON l.hub_device_hk = hd.hub_device_hk
JOIN staging.device_registry dr ON hd.device_id = dr.device_id
WHERE rm.reading_ts >= DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY dr.cluster_id;
-- 3 JOINs through hash keys, plus the seed table for cluster info
```

### Pros
- **Full history by default** — every change to every attribute is tracked forever
- **Parallel loading** — Hubs, Links, and Satellites can be loaded independently
- **Resilient to source changes** — add a new source? Add a satellite, nothing else changes
- **Audit-friendly** — every row has load_ts, record_source, hashdiff
- **Scales to enterprise** — handles hundreds of sources feeding the same hub

### Cons
- **Most complex to query** — analysts can't use it directly, need a "business vault" or mart layer on top
- **Most tables** — 5 tables for what Star Schema does in 2
- **Over-engineering for single-source systems** — Data Vault shines with 10+ sources
- **Hash keys are unreadable** — debugging requires joining back to hubs

### When to Use
- **Enterprise data warehouses** with many source systems feeding the same entities
- When you need **full audit trail** of every change
- When sources are added/removed frequently
- **Regulated industries** (finance, healthcare) where data lineage is required
- When you have a **dedicated DV team** who understands the methodology

### When NOT to Use
- Small teams, single source system (our project — Data Vault is overkill here)
- When analysts need to query directly (they need a mart layer on top)
- Prototyping or MVP stage

---

## 4. One Big Table — OBT (`models/obt/`)

```
┌─────────────────────────────────────────────────────────────────┐
│                     obt_fleet_readings                           │
│                                                                  │
│  reading_id | device_id | temperature | humidity | device_name   │
│  device_type | cluster_id | install_date | threshold_min/max    │
│  anomaly_severity | battery_status | hour_of_day | is_weekend   │
│  reading_hour | reading_date | gps_drift_km | ...               │
│                                                                  │
│  (35+ columns, everything pre-joined and pre-computed)          │
└─────────────────────────────────────────────────────────────────┘
```

### How It Works
- **One table. Zero JOINs.** Everything denormalized into a single wide table.
- Device attributes repeated on every reading row
- Time dimensions pre-computed as columns
- Thresholds, anomaly severity, battery status all pre-calculated

### The SQL
```sql
-- Average temp per cluster, last 24h — OBT
SELECT cluster_id, AVG(temperature) AS avg_temp
FROM obt.obt_fleet_readings
WHERE reading_ts >= DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY cluster_id;
-- 0 JOINs! Just filter and aggregate.
```

### Pros
- **Fastest queries** — zero JOINs, everything pre-computed
- **Simplest for analysts** — one table, `SELECT *` to see everything
- **Perfect for BI tools** — Looker, Tableau, Streamlit work best with flat tables
- **Snowflake handles it well** — columnar storage means unused columns cost nothing

### Cons
- **Data duplication** — "FACTORY_A" repeated on every row from those 10 devices
- **Expensive updates** — if device_name changes, update millions of rows
- **Wide tables** — 35+ columns can be overwhelming
- **No clear ownership** — who maintains this mega-table?
- **Storage overhead** — more data stored (minor in Snowflake due to compression)

### When to Use
- **Analytics/BI layer** — the final table analysts and dashboards query
- **Ad-hoc exploration** — data scientists exploring in notebooks
- **Small-medium datasets** — where duplication cost is negligible
- When query speed matters more than storage efficiency

---

## Side-by-Side Comparison

| Criteria | Star Schema | Snowflake Schema | Data Vault | OBT |
|----------|------------|------------------|------------|-----|
| **JOINs for "temp by cluster"** | 1 | 3 | 3 | 0 |
| **Tables in our model** | 7 | 5 | 5 | 1 |
| **Query complexity** | Low | Medium | High | Lowest |
| **Update complexity** | Low | Lowest | Append-only | Highest |
| **History tracking** | Manual (SCD) | Manual (SCD) | Automatic | None |
| **Storage efficiency** | Good | Best | Good | Worst |
| **Analyst-friendly** | Yes | Somewhat | No (need mart) | Most |
| **Multi-source ready** | Somewhat | Somewhat | Built for it | No |
| **Best for** | General analytics | Large normalized DW | Enterprise, audit | BI dashboards |
| **Overkill for** | Nothing | Small datasets | Single-source | Frequent dim changes |

---

## The Real-World Answer

Most production data platforms use **a combination**:

```
Sources → Staging → Data Vault (raw vault) → Star Schema (marts) → OBT (BI layer)
```

Or more commonly for small-medium teams:

```
Sources → Staging → Intermediate → Star Schema (marts)
```

Which is exactly what our default pipeline does. The other models exist in this project for **learning and comparison** — in practice, you'd pick one approach per layer, not build all four.

### Decision Framework

1. **Small team, single source, analytics focus** → Star Schema (our default)
2. **Small team, BI-heavy** → Star Schema + OBT for the dashboard layer
3. **Enterprise, multiple sources, audit requirements** → Data Vault + Star Schema marts
4. **Snowflake Schema** → Rarely used alone today. Its ideas (time dimensions, surrogate keys) get borrowed into Star Schema when needed.

---

## Running the Models

```bash
# Run all 4 approaches
dbt run --select data_vault
dbt run --select obt
dbt run --select snowflake_schema

# Run the comparison view
dbt run --select compare_models

# Test them
dbt test --select data_vault obt snowflake_schema
```

Then in Snowflake, compare:
```sql
-- Star Schema
SELECT * FROM IOT_PIPELINE.MARTS.fct_hourly_readings LIMIT 5;

-- Data Vault
SELECT * FROM IOT_PIPELINE.DATA_VAULT.hub_device LIMIT 5;
SELECT * FROM IOT_PIPELINE.DATA_VAULT.sat_reading_metrics LIMIT 5;

-- OBT
SELECT * FROM IOT_PIPELINE.OBT.obt_fleet_readings LIMIT 5;

-- Snowflake Schema
SELECT * FROM IOT_PIPELINE.SNOWFLAKE_SCHEMA.fct_readings_normalized LIMIT 5;
SELECT * FROM IOT_PIPELINE.SNOWFLAKE_SCHEMA.dim_cluster;
SELECT * FROM IOT_PIPELINE.SNOWFLAKE_SCHEMA.dim_device_type;
```
