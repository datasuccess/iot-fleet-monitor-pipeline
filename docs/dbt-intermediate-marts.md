# Phase 5 — Intermediate, Marts & Snapshots Explained

## Intermediate Layer: Data Cleaning Pipeline

The intermediate layer is where raw staged data gets cleaned, validated, and enriched before reaching the marts. Think of it as a factory assembly line.

### 1. Deduplication (`int_readings_deduped`)

**Problem**: IoT devices often send duplicate readings (network retries, buffered uploads).

**Solution**: `ROW_NUMBER()` window function:
```sql
row_number() over (
    partition by device_id, reading_ts
    order by loaded_at desc
) as row_num
```
- **partition by** groups rows that have the same device + timestamp (duplicates)
- **order by loaded_at desc** picks the most recently loaded copy (freshest)
- Keep only `row_num = 1`

**Why incremental?** We only process new data each run (`where loaded_at > max from this table`). This saves compute — instead of re-deduplicating millions of rows, we only handle the latest batch.

### 2. Validation (`int_readings_validated`)

**Problem**: Sensors send garbage data — negative humidity, 9999°C temperatures, etc.

**Two validation approaches**:

**Range checks** — Compare against known physical limits from `sensor_thresholds` seed:
```sql
temperature between t_thresh.min_valid and t_thresh.max_valid
```

**Z-score anomaly detection** — Statistical approach for subtle anomalies:
```sql
(temperature - avg(temperature) over w) / nullif(stddev(temperature) over w, 0)
```
- Z-score tells you how many standard deviations a value is from the mean
- |z| > 3 means the value is in the 0.3% tail — very unusual
- Window of 12 preceding readings (1 hour of data at 5-min intervals)

**Why both?** Range checks catch impossible values (temp = -999). Z-scores catch values that are physically possible but statistically suspicious (temp jumps from 22°C to 45°C).

### 3. Enrichment (`int_readings_enriched`)

Joins validated readings with device metadata (cluster, type, location) and adds **time dimensions**:
- `hour_of_day`, `day_of_week` — for pattern analysis
- `is_weekend`, `is_business_hours` — for alerting thresholds

**Why a separate step?** Keeps validation logic clean. Enrichment is about adding context, not filtering.

### 4. Quarantine Pattern (`int_quarantined_readings`)

**Problem**: You can't just delete bad data — you need to know what went wrong and why.

**Solution**: Route bad records to a quarantine table with rejection reasons:
```sql
array_construct_compact(
    case when temperature is null then 'null_temperature' end,
    case when not is_temperature_valid then 'temperature_out_of_range' end,
    ...
)
```

`ARRAY_CONSTRUCT_COMPACT` builds an array but skips NULLs — so you get only the reasons that apply: `['null_temperature', 'humidity_out_of_range']`.

**Real-world use**: Data engineers review quarantine tables to spot systematic issues (a batch of faulty sensors, a firmware bug, etc.).

### 5. Late Arrivals (`int_late_arriving_readings`)

**Problem**: A device might buffer readings when offline and send them hours later.

**Detection**: `loaded_at - reading_ts > 60 minutes`

**Why track these?** Late data can break incremental models if not handled. It also indicates connectivity issues.

---

## Marts Layer: Business-Ready Analytics

### `dim_devices` — Device Dimension

A **dimension table** describes entities (who/what). One row per device with attributes from the seed file + live metadata. Uses `COALESCE` to prefer live data over seed defaults.

### `fct_hourly_readings` — Fact Table

A **fact table** records events/measurements. Aggregates raw readings to hourly grain:
- `avg`, `min`, `max`, `stddev` for each sensor
- `anomaly_count` per hour

**Why hourly?** Raw 5-minute data is too granular for dashboards. Hourly is the sweet spot for monitoring.

### `fct_device_health` — Health Scoring

Computes daily device health:
- **Battery drain rate**: `(last_battery - first_battery) / hours` using `max_by`/`min_by`
- **Uptime**: `readings_received / 288` (288 = 12/hour × 24 hours)
- **Health status**: Rules-based classification → `critical`, `warning`, `healthy`

### `fct_anomalies` — Anomaly Log

UNION ALL across 4 sensor types (temperature, humidity, pressure, battery). Each anomaly gets:
- `anomaly_type`: zscore or out_of_range
- `severity`: critical/warning/info based on threshold bands
- `zscore`: how extreme the value was (temperature only)

**Why UNION ALL?** Each sensor type has different thresholds and logic. UNION ALL stacks them into a single queryable log.

### `fct_data_quality` — Quality Scorecard

Per-batch quality metrics:
- **null_pct**: % of fields that are NULL (out of 4 sensor fields)
- **duplicate_pct**: % of records that were duplicates
- **quality_score**: `100 - (null_penalty × 0.5) - (dup_penalty × 0.3) - (quarantine_penalty × 0.2)`

Weighted formula penalizes different quality issues proportionally.

### `rpt_fleet_overview` — Executive Report

Joins health + quality + anomalies into one daily summary. Uses `LEFT JOIN` because some days might have no anomalies or no quality issues.

---

## SCD Type 2 Snapshot

**Problem**: Device metadata changes over time (firmware updates, relocations). You need to know what the metadata was at any historical point.

**Solution**: dbt snapshot with `strategy='check'`:
```sql
check_cols=['firmware_version', 'cluster_id', 'device_type', 'latitude', 'longitude']
```

dbt automatically manages:
- `dbt_valid_from` — when this version became active
- `dbt_valid_to` — when it was superseded (NULL = current)
- `dbt_scd_id` — unique ID for each version

**Example**: Device D001 moves from NYC to LA cluster:
| device_id | cluster_id | dbt_valid_from | dbt_valid_to |
|-----------|-----------|----------------|--------------|
| D001 | nyc_central | 2026-01-01 | 2026-03-15 |
| D001 | la_downtown | 2026-03-15 | NULL |

---

## Custom Macros

### `deduplicate`
Generic macro — pass any relation, partition columns, and sort order. Returns deduplicated subquery. Reusable across projects.

### `classify_anomaly`
Encapsulates the threshold lookup logic. Generates a CASE expression that classifies severity based on the `sensor_thresholds` seed.

### `safe_cast_numeric`
Wraps `TRY_CAST` for VARIANT fields. Returns NULL instead of erroring on bad data. Parameterized precision/scale.

---

## Custom Singular Tests

| Test | What it catches |
|------|----------------|
| `test_no_future_timestamps` | Clock drift, data corruption |
| `test_gps_coordinates_valid` | Invalid lat/long in device registry |
| `test_quarantine_has_reasons` | Logic bug — quarantined without explanation |
| `test_deduped_no_duplicates` | Dedup logic failure |
| `test_quality_score_range` | Score formula producing impossible values |

**How singular tests work**: Any rows returned = test failure. An empty result = pass. This is the opposite of generic tests (which are defined in YAML).

---

## Key Patterns to Remember

1. **Incremental + merge**: Process only new data, upsert on surrogate key
2. **Quarantine, don't delete**: Bad data is valuable for debugging
3. **Statistical + rule-based validation**: Catch both impossible and improbable values
4. **Surrogate keys**: `dbt_utils.generate_surrogate_key` creates deterministic hashes
5. **Window functions**: Core tool for dedup, z-scores, and time-series analysis
6. **Layered architecture**: staging (parse) → intermediate (clean) → marts (aggregate)
