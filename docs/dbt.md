# dbt — Staging, Intermediate, Marts & Snapshots

## Staging Layer: Parse Raw Data

### VARIANT Parsing with TRY_CAST (stg_sensor_readings.sql)

```sql
try_cast(raw_data:temperature as float) as temperature
```

- `raw_data:temperature` — Extract field from JSON VARIANT
- `try_cast(... as float)` — Convert to float, return NULL on failure
- Regular `cast()` errors on bad data. `try_cast()` returns NULL — critical for dirty data.

**Why views?** Staging = `materialized='view'`. No storage cost, always shows latest data.

### Source Freshness (_sources.yml)

```yaml
freshness:
  warn_after: {count: 30, period: minute}
  error_after: {count: 60, period: minute}
loaded_at_field: loaded_at
```

`dbt source freshness` checks when last row was loaded. Catches silent pipeline failures.

### dbt_expectations Tests (_staging.yml)

```yaml
- dbt_expectations.expect_column_values_to_be_between:
    min_value: -50
    max_value: 120
    mostly: 0.90
```

`mostly: 0.90` = passes if 90% of values in range. Without it, a single error-injected value fails the whole test.

### Contract Tests

```yaml
- name: reading_id
  tests: [not_null, unique]
- name: device_id
  tests:
    - relationships:
        to: ref('device_registry')
        field: device_id
```

Enforces data contracts. If upstream changes break these, dbt tests catch it immediately.

### Custom Schema Naming (generate_schema_name.sql)

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

Writes to `STAGING`, `INTERMEDIATE`, `MARTS` directly (no `RAW_STAGING` prefix).

### Seeds

CSV files loaded as tables for reference data that rarely changes:
- `device_registry.csv` — 50 devices with cluster, type, location
- `sensor_thresholds.csv` — Valid ranges per sensor type
- `cluster_metadata.csv` — Cluster city, timezone, environment, manager

### Safe VARIANT Extraction Macro

```sql
{% macro parse_json_field(variant_column, field_name, cast_type='varchar') -%}
    try_cast({{ variant_column }}:{{ field_name }} as {{ cast_type }})
{%- endmacro %}
```

### Device Metadata (stg_device_metadata.sql)

Window function to get **latest** metadata per device:
```sql
row_number() over (partition by device_id order by loaded_at desc) as rn
-- where rn = 1
```

---

## Intermediate Layer: Data Cleaning Pipeline

### 1. Deduplication (int_readings_deduped)

IoT devices often send duplicate readings (network retries, buffered uploads).

```sql
row_number() over (
    partition by device_id, reading_ts
    order by loaded_at desc
) as row_num
-- Keep only row_num = 1 (most recently loaded copy)
```

**Incremental**: Only processes new data each run (`where loaded_at > max from this table`).

### 2. Validation (int_readings_validated)

Two approaches:

**Range checks** — Against `sensor_thresholds` seed:
```sql
temperature between t_thresh.min_valid and t_thresh.max_valid
```

**Z-score anomaly detection** — Statistical:
```sql
(temperature - avg(temperature) over w) / nullif(stddev(temperature) over w, 0)
```
- |z| > 3 = value in 0.3% tail (very unusual)
- Window of 12 preceding readings (1 hour at 5-min intervals)

**Why both?** Range checks catch impossible values (temp = -999). Z-scores catch statistically suspicious values (temp jumps from 22°C to 45°C).

### 3. Enrichment (int_readings_enriched)

Joins validated readings with device metadata + adds time dimensions:
- `hour_of_day`, `day_of_week`, `is_weekend`, `is_business_hours`

### 4. Quarantine (int_quarantined_readings)

Bad records routed with rejection reasons:
```sql
array_construct_compact(
    case when temperature is null then 'null_temperature' end,
    case when not is_temperature_valid then 'temperature_out_of_range' end,
    ...
)
```

`ARRAY_CONSTRUCT_COMPACT` builds array, skips NULLs → only applicable reasons.

### 5. Late Arrivals (int_late_arriving_readings)

Detection: `loaded_at - reading_ts > 60 minutes`. Indicates connectivity issues and can break incremental models.

---

## Marts Layer: Business-Ready Analytics

### dim_devices — Device Dimension
One row per device with attributes from seed + live metadata. `COALESCE` prefers live data over seed defaults.

### dim_clusters — Cluster Dimension
Location, timezone, environment, manager from `cluster_metadata` seed.

### fct_hourly_readings — Fact Table
Hourly aggregations: `avg`, `min`, `max`, `stddev` per sensor. Including CO2 metrics for firmware >= 2.0.0 devices.

### fct_device_health — Health Scoring
- **Battery drain rate**: `(last_battery - first_battery) / hours`
- **Uptime**: `readings_received / 288` (288 = 12/hour × 24 hours)
- **Health status**: Rules-based → `critical`, `warning`, `healthy`

### fct_anomalies — Anomaly Log
UNION ALL across 5 sensor types (temperature, humidity, pressure, battery, CO2). Each gets `anomaly_type`, `severity`, `zscore`.

### fct_data_quality — Quality Scorecard
Per-batch: `null_pct`, `duplicate_pct`, `quality_score = 100 - (null × 0.5) - (dup × 0.3) - (quarantine × 0.2)`

### rpt_fleet_overview — Executive Report
Joins health + quality + anomalies into daily summary via LEFT JOINs.

---

## SCD Type 2 Snapshot

Device metadata changes over time (firmware updates, relocations). dbt snapshot with `strategy='check'`:

```sql
check_cols=['firmware_version', 'cluster_id', 'device_type', 'latitude', 'longitude']
```

dbt manages `dbt_valid_from`, `dbt_valid_to` (NULL = current), `dbt_scd_id`.

| device_id | cluster_id | dbt_valid_from | dbt_valid_to |
|-----------|-----------|----------------|--------------|
| D001 | nyc_central | 2026-01-01 | 2026-03-15 |
| D001 | la_downtown | 2026-03-15 | NULL |

---

## Custom Macros

| Macro | Purpose |
|-------|---------|
| `deduplicate` | Generic dedup — pass relation, partition cols, sort order |
| `classify_anomaly` | Threshold lookup → CASE expression for severity |
| `safe_cast_numeric` | `TRY_CAST` wrapper for VARIANT fields |

## Custom Singular Tests

| Test | Catches |
|------|---------|
| `test_no_future_timestamps` | Clock drift, data corruption |
| `test_gps_coordinates_valid` | Invalid lat/long in device registry |
| `test_quarantine_has_reasons` | Quarantined without explanation |
| `test_deduped_no_duplicates` | Dedup logic failure |
| `test_quality_score_range` | Score formula producing impossible values |

Singular tests: rows returned = failure. Empty result = pass.

---

## Key Patterns

1. **Incremental + merge**: Process only new data, upsert on surrogate key
2. **Quarantine, don't delete**: Bad data is valuable for debugging
3. **Statistical + rule-based validation**: Catch both impossible and improbable values
4. **Surrogate keys**: `dbt_utils.generate_surrogate_key` creates deterministic hashes
5. **Window functions**: Core tool for dedup, z-scores, time-series analysis
6. **Layered architecture**: staging (parse) → intermediate (clean) → marts (aggregate)

## File Structure

```
dbt/iot_pipeline/
├── dbt_project.yml              # Project config + schema mappings
├── profiles.yml                 # Snowflake connection (env vars)
├── packages.yml                 # dbt_utils + dbt_expectations
├── models/
│   ├── staging/                 # Parse VARIANT → typed columns
│   ├── intermediate/            # Dedup, validate, enrich, quarantine
│   └── marts/                   # Dimensions, facts, reports
├── macros/                      # Reusable SQL logic
├── seeds/                       # Reference CSV data
├── snapshots/                   # SCD Type 2
└── tests/                       # Custom singular tests
```
