# Schema Evolution — Evolving a Live Pipeline Without Downtime

How to add new fields, new sources, and new dimensions to a running data pipeline without breaking anything. Real examples from our IoT Fleet Monitor Pipeline.

---

## What We Changed (Phase 11)

| Change | Type | Downtime? |
|--------|------|-----------|
| Add `co2_level` sensor field | New column, backwards-compatible | Zero |
| Add `dim_clusters` dimension | New table | Zero |
| Add CO2 thresholds | Seed data update | Zero |
| Update all dbt models | SQL changes | Zero (next `dbt run` picks it up) |

---

## Why Schema Evolution Is Hard

In a traditional database, adding a column means:
```sql
ALTER TABLE readings ADD COLUMN co2_level FLOAT;
-- Every existing row now has NULL for co2_level
-- Every INSERT must account for the new column
-- Every downstream query might break
```

In a data pipeline, it's worse — you have **7+ layers** that all need to agree:
```
Lambda → S3 → Snowflake RAW → Staging → Intermediate → Marts → Dashboards
```

If any layer doesn't handle the new field, the pipeline breaks.

---

## Why Our Pipeline Handles It Gracefully

### 1. VARIANT Column in Raw Layer (The Key Enabler)

```sql
-- Raw table stores the ENTIRE JSON as-is
CREATE TABLE sensor_readings (
    raw_data    VARIANT,       -- accepts ANY JSON structure
    loaded_at   TIMESTAMP_NTZ,
    source_file VARCHAR
);
```

When Lambda starts sending `co2_level`, it lands in the VARIANT column automatically. **No `ALTER TABLE` needed.** Old readings don't have it, new readings do — both coexist in the same table.

This is the #1 reason we chose ELT over ETL. The raw layer absorbs ANY schema change without breaking.

### 2. TRY_CAST in Staging (Safe Parsing)

```sql
-- stg_sensor_readings.sql
try_cast(raw_data:co2_level::varchar as float) as co2_level
```

- If `co2_level` exists in the JSON → parses to float
- If `co2_level` doesn't exist (old readings) → returns NULL
- If `co2_level` has a bad value → returns NULL (not an error)

**No conditional logic needed.** `TRY_CAST` handles both old and new data in the same query.

### 3. Incremental Models (Only Process New Data)

```sql
{% if is_incremental() %}
where loaded_at > (select max(loaded_at) from {{ this }})
{% endif %}
```

When we add `co2_level` to intermediate models, existing rows in the target table stay unchanged. Only new rows (which may or may not have CO2 data) get processed. Historical data keeps its NULL co2_level without needing a backfill.

### 4. NULL-Safe Aggregations in Marts

```sql
-- fct_hourly_readings.sql
avg(co2_level) as avg_co2_level   -- AVG ignores NULLs
min(co2_level) as min_co2_level   -- MIN ignores NULLs
max(co2_level) as max_co2_level   -- MAX ignores NULLs
```

SQL aggregate functions skip NULLs by default. Devices without CO2 sensors produce NULL — aggregations still work. No `COALESCE` or special handling needed.

### 5. Conditional Validation (NULL ≠ Invalid)

```sql
-- int_readings_validated.sql
case
    when d.co2_level is null then true       -- No sensor = valid (not an error)
    when d.co2_level between 300 and 2000 then true  -- In range = valid
    else false                                -- Has sensor but out of range = invalid
end as is_co2_valid
```

Critical distinction: a missing field (old firmware, no CO2 sensor) is **not a validation failure**. Only devices that HAVE the sensor but report bad values get quarantined.

---

## The Change Walkthrough

### Step 1: Lambda Generator (Producer)

**What changed:**
- `config.py`: Added CO2 to `SENSOR_RANGES` (300-2000 ppm) and `RANDOM_WALK` (step_size=15, mean_reversion=0.04)
- `models.py`: Added `co2_level: Optional[float]` to SensorReading
- `sensors.py`: DeviceState generates CO2 via random walk, but **only for firmware >= 2.0.0**
- `errors.py`: Added `co2_level` to SENSOR_FIELDS (error injection applies to it too)

**Key design decision:** Not all devices get CO2. Only firmware >= 2.0.0 devices have the sensor. This simulates reality — hardware upgrades don't happen overnight. The pipeline must handle a mix of old and new data simultaneously.

**Backwards compatibility:** Old Lambda code produces readings without `co2_level`. New Lambda code produces readings with or without it (depending on firmware). Both are valid JSON that COPY INTO handles identically.

### Step 2: Snowflake Raw (No Change!)

Zero changes. VARIANT accepts any JSON structure. This is the entire point of schema-on-read.

### Step 3: dbt Staging

Added one line:
```sql
try_cast(raw_data:co2_level::varchar as float) as co2_level
```

Added schema test:
```yaml
- name: co2_level
  tests:
    - dbt_expectations.expect_column_values_to_be_between:
        min_value: 100
        max_value: 5000
        row_condition: "co2_level is not null"
```

### Step 4: dbt Intermediate

- **int_readings_deduped**: Pass through `co2_level` column
- **int_readings_validated**: Add `is_co2_valid` range check + join to CO2 thresholds + include in `validation_error_count`
- **int_readings_enriched**: Pass through `co2_level` column
- **int_quarantined_readings**: Pass through `co2_level` + add `CO2_OUT_OF_RANGE` rejection reason

### Step 5: dbt Marts

- **fct_hourly_readings**: Add `avg_co2_level`, `min_co2_level`, `max_co2_level`
- **fct_anomalies**: Add CO2 anomaly UNION ALL block

### Step 6: Seeds

- **sensor_thresholds.csv**: Added `co2,300,2000,400,1500,300,2000`
- **cluster_metadata.csv**: New seed for dim_clusters (city, timezone, environment, manager)

---

## New Dimension: dim_clusters

Previously, cluster attributes (city, timezone) were scattered or hardcoded. Now they live in a proper dimension table:

```
cluster_id | cluster_city | cluster_state | cluster_timezone | environment_type | manager_name
FACTORY_A  | New York     | NY            | America/New_York | indoor_stable    | Sarah Chen
OUTDOOR    | Seattle      | WA            | America/Los_Angeles | outdoor       | Anna Petrov
```

This follows the star schema pattern — descriptive attributes in a dimension, not on the fact table.

---

## Backfill Strategies

### Option 1: No Backfill (What We Did)
Historical rows have `co2_level = NULL`. Aggregations handle NULLs correctly. Dashboards show "N/A" for periods before CO2 was deployed. This is the simplest and safest approach.

### Option 2: Full Refresh
```bash
dbt run --full-refresh --select int_readings_deduped+
```
Rebuilds all incremental models from scratch. Every row re-processes through the new logic. Use this when the model logic changed fundamentally (not just adding a column).

### Option 3: Targeted Reprocess
```sql
-- Delete specific date range from target, then re-run incrementally
DELETE FROM int_readings_deduped WHERE loaded_at BETWEEN '2026-04-01' AND '2026-04-03';
-- Next dbt run picks up those rows again with the new logic
```

### Option 4: COPY INTO with FORCE
```sql
-- Re-load specific S3 files that need reprocessing
COPY INTO sensor_readings FROM @stage
  PATTERN = '.*2026/04/01.*'
  FORCE = TRUE;
```
Use when raw data needs re-ingestion (rare).

---

## Rules for Zero-Downtime Schema Evolution

1. **Never remove columns from the producer until all consumers have stopped using them.** Add new columns freely — removing is the dangerous direction.

2. **Use VARIANT/JSON for raw storage.** Schema-on-read absorbs any change. Schema-on-write (typed columns in raw) breaks on the first unexpected field.

3. **Use TRY_CAST, not CAST.** `CAST('bad' as float)` = error. `TRY_CAST('bad' as float)` = NULL. One crashes your pipeline, the other gracefully degrades.

4. **Treat NULL as "not applicable", not "error".** A device without a CO2 sensor should not be quarantined for missing CO2 data. Validate presence only where the field is expected.

5. **Add to seeds before deploying the producer.** Run `dbt seed` with the new thresholds BEFORE Lambda starts sending CO2 data. Otherwise, the validation join finds no threshold and everything passes (or fails, depending on your logic).

6. **Deploy in order: seeds → dbt models → producer.** This ensures the pipeline can handle new data before it arrives. If you deploy Lambda first, readings with `co2_level` arrive but dbt doesn't parse them yet — they're ignored (land in VARIANT, not parsed until staging model is updated). Safe but not ideal.

---

## Interview Talking Points

**"How do you handle schema changes in your pipeline?"**

"Our raw layer uses Snowflake VARIANT columns — semi-structured JSON that accepts any schema. When we added a CO2 sensor field, zero changes were needed at the raw layer. The staging model uses TRY_CAST to parse new fields safely — it returns NULL for old readings that don't have the field. Intermediate models validate with NULL-awareness: a missing field isn't a validation failure, only an out-of-range value is. Mart aggregations use AVG/MIN/MAX which skip NULLs naturally. The entire change was deployed without downtime — we updated dbt models, ran `dbt seed` for new thresholds, deployed the updated Lambda, and the pipeline absorbed it seamlessly."

**"What if you need to rename a column?"**

"Renaming is harder than adding because downstream consumers break. Our approach: add the new column name, keep the old one as an alias, update all consumers, then remove the old column in a later release. The staging model can map both: `COALESCE(raw_data:temperature, raw_data:temp_celsius) as temperature`. Our error injection already simulates this with `inject_schema_drift` which renames `temperature` to `temp_celsius`."

**"What about breaking changes — removing a field entirely?"**

"We follow the expand-and-contract pattern from API versioning. Step 1: Add a deprecation notice (column comment, team communication). Step 2: Stop reading the column in dbt (but keep parsing it). Step 3: Stop producing it in Lambda. Step 4: Remove from dbt models after a retention period. Each step is a separate deployment. If anything breaks, we roll back one step."
