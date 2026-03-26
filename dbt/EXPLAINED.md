# Phase 4: dbt Staging Models — Code Explained

## 1. VARIANT Parsing with TRY_CAST (stg_sensor_readings.sql)

```sql
try_cast(raw_data:temperature as float) as temperature
```

Raw data is stored as VARIANT (a single JSON blob). Staging models **parse** it into typed columns.

- `raw_data:temperature` — Extract the `temperature` field from JSON
- `try_cast(... as float)` — Convert to float, return NULL if it fails
- Regular `cast()` would **error** on bad data. `try_cast()` returns **NULL** — critical for dirty data.

**Why views?** Staging models are `materialized='view'`. They don't store data — they're just a SQL lens on top of raw. Fast to create, no storage cost, always shows latest data.

---

## 2. Source Freshness (_sources.yml)

```yaml
freshness:
  warn_after: {count: 30, period: minute}
  error_after: {count: 60, period: minute}
loaded_at_field: loaded_at
```

Run `dbt source freshness` and dbt checks: "When was the last row loaded?"
- Last load < 30 min ago → PASS
- 30-60 min ago → WARN
- \> 60 min ago → ERROR

This catches silent pipeline failures — data stops flowing but nobody notices.

---

## 3. dbt_expectations Tests (_staging.yml)

```yaml
- dbt_expectations.expect_column_values_to_be_between:
    min_value: -50
    max_value: 120
    mostly: 0.90
```

`dbt_expectations` is inspired by Great Expectations. The `mostly` parameter is key:
- `mostly: 0.90` = test passes if **90%** of values are in range
- Without `mostly`, a single out-of-range value (from error injection) fails the entire test
- This lets you set quality **thresholds** instead of absolute rules

---

## 4. Contract Tests (_staging.yml)

```yaml
- name: reading_id
  tests:
    - not_null
    - unique
- name: device_id
  tests:
    - relationships:
        to: ref('device_registry')
        field: device_id
```

These enforce the **data contract**:
- `not_null` + `unique` on reading_id = every reading has a unique ID
- `relationships` = every device_id must exist in the device_registry seed

If upstream changes break these contracts, dbt tests catch it immediately.

---

## 5. Custom Schema Naming (generate_schema_name.sql)

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

By default, dbt prefixes schemas: `RAW_STAGING`. Our macro overrides this so dbt writes to `STAGING` directly. This matches our Snowflake schema layout:
- `IOT_PIPELINE.STAGING.stg_sensor_readings`
- `IOT_PIPELINE.INTERMEDIATE.int_readings_deduped`
- `IOT_PIPELINE.MARTS.fct_hourly_readings`

---

## 6. Seeds (device_registry.csv, sensor_thresholds.csv)

Seeds are CSV files that dbt loads into Snowflake as tables. They're for **reference data** that rarely changes.

- `device_registry.csv` — 50 devices with cluster, type, location
- `sensor_thresholds.csv` — Valid ranges per sensor type (used for validation in Phase 5)

Run `dbt seed` to load them. They become referenceable as `{{ ref('device_registry') }}`.

---

## 7. Safe VARIANT Extraction Macro (parse_json_field.sql)

```sql
{% macro parse_json_field(variant_column, field_name, cast_type='varchar') -%}
    try_cast({{ variant_column }}:{{ field_name }} as {{ cast_type }})
{%- endmacro %}
```

Reusable macro for extracting VARIANT fields. Instead of writing:
```sql
try_cast(raw_data:temperature as float) as temperature
```

You can write:
```sql
{{ parse_json_field('raw_data', 'temperature', 'float') }} as temperature
```

Both produce the same SQL. The macro is useful when you have many fields to extract.

---

## 8. Device Metadata (stg_device_metadata.sql)

```sql
row_number() over (
    partition by device_id
    order by loaded_at desc
) as rn
...
where rn = 1
```

Each device appears in many readings. This model extracts the **latest** metadata per device using a window function. `partition by device_id` groups by device, `order by loaded_at desc` sorts newest first, `rn = 1` keeps only the latest.

This feeds into the SCD Type 2 snapshot in Phase 5 — when a device's firmware changes, the snapshot tracks the history.

---

## File Structure

```
dbt/iot_pipeline/
├── dbt_project.yml              # Project config + schema mappings
├── profiles.yml                 # Snowflake connection (env vars)
├── packages.yml                 # dbt_utils + dbt_expectations
├── models/staging/
│   ├── _sources.yml             # Raw source + freshness checks
│   ├── _staging.yml             # Tests (contract + quality)
│   ├── stg_sensor_readings.sql  # Parse VARIANT → typed columns
│   └── stg_device_metadata.sql  # Latest metadata per device
├── macros/
│   ├── generate_schema_name.sql # Custom schema naming
│   └── parse_json_field.sql     # Safe VARIANT extraction
└── seeds/
    ├── device_registry.csv      # 50 devices reference data
    └── sensor_thresholds.csv    # Valid ranges per sensor
```
