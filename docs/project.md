# Project Specification — IoT Fleet Monitor Pipeline

## Domain

An industrial IoT fleet of **50 sensor devices** deployed across 5 geographic clusters (factory floors, warehouses, outdoor stations). Each device reports every **5 minutes**:

| Metric | Unit | Normal Range | Description |
|--------|------|-------------|-------------|
| Temperature | °C | -20 to 60 | Ambient temperature |
| Humidity | % | 10 to 95 | Relative humidity |
| Pressure | hPa | 950 to 1050 | Atmospheric pressure |
| Battery | % | 0 to 100 | Device battery level (slowly draining) |
| CO2 | ppm | 300 to 2000 | CO2 level (firmware >= 2.0.0 only) |
| Latitude/Longitude | ° | varies by cluster | GPS coordinates |

**Daily volume**: 50 devices × 288 readings/day = **14,400 readings/day**

---

## Device Fleet

| Cluster | Location | Devices | Environment |
|---------|----------|---------|-------------|
| FACTORY_A | NYC (40.71, -74.01) | DEV_001–DEV_010 | Indoor, stable temp |
| FACTORY_B | LA (34.05, -118.24) | DEV_011–DEV_020 | Indoor, warm |
| WAREHOUSE_A | Chicago (41.88, -87.63) | DEV_021–DEV_030 | Semi-outdoor, variable |
| WAREHOUSE_B | Houston (29.76, -95.37) | DEV_031–DEV_040 | Semi-outdoor, humid |
| OUTDOOR | Seattle (47.61, -122.33) | DEV_041–DEV_050 | Outdoor, rain/cold |

Each device has: `device_id`, `device_type` (A/B/C), `firmware_version`, `install_date`, `cluster_id`

---

## Data Flow

```
1. Lambda (generate) → 2. S3 (raw JSON) → 3. Snowflake RAW (VARIANT)
                                                    ↓
                                               4. dbt transforms
                                          (staging → intermediate → marts)
                                                    ↓
                                         5. Iceberg tables (Parquet on S3)
                                                    ↓
                                          6. Monitoring & Alerts

                        Airflow orchestrates every step
```

### 1. Generation (Lambda)
Triggered on schedule (EventBridge) or on-demand. Random walk for sensor values. Error injection via profiles (none/normal/high/chaos).

### 2. Landing (S3)
`s3://bucket/sensor_readings/year=YYYY/month=MM/day=DD/hour=HH/batch_{ts}.json`

### 3. Ingestion (Snowflake RAW)
`COPY INTO` from S3 stage → VARIANT column. Snowpipe available for auto-ingest.

### 4. Transformation (dbt)
- **Staging**: Parse VARIANT → typed columns with TRY_CAST
- **Intermediate**: Dedup → Validate (range + z-score) → Enrich → Quarantine → Late arrivals
- **Marts**: dim_devices, dim_clusters, fct_hourly_readings, fct_device_health, fct_anomalies, fct_data_quality, rpt_fleet_overview

### 5. Curated Storage (Iceberg)
Mart tables as Snowflake-managed Iceberg tables. Parquet on S3, queryable by Spark, Trino, DuckDB.

### 6. Monitoring
Quality dashboards, alert rules, row count anomaly detection.

---

## Snowflake Object Model

```
IOT_PIPELINE (database)
├── RAW
│   ├── sensor_readings      — VARIANT, raw JSON
│   └── load_audit_log       — Load metadata
├── STAGING
│   ├── stg_sensor_readings  — Parsed, typed columns
│   └── stg_device_metadata  — Latest metadata per device
├── INTERMEDIATE
│   ├── int_readings_deduped
│   ├── int_readings_validated
│   ├── int_readings_enriched
│   ├── int_quarantined_readings
│   └── int_late_arriving_readings
├── MARTS (Iceberg → Parquet on S3)
│   ├── dim_devices, dim_clusters
│   ├── fct_hourly_readings, fct_device_health, fct_anomalies, fct_data_quality
│   └── rpt_fleet_overview
└── MONITORING
    └── freshness_log
```

**Roles**: IOT_LOADER (write RAW), IOT_TRANSFORMER (read/write all), IOT_READER (read MARTS)
**Warehouse**: IOT_WH — X-Small, auto-suspend 60s

---

## Entity Relationship Diagram

```mermaid
erDiagram
    RAW_SENSOR_READINGS {
        variant raw_data "Entire JSON payload"
        timestamp loaded_at "When COPY INTO ran"
        string source_file "S3 file path"
    }

    STG_SENSOR_READINGS {
        string reading_id PK
        string device_id FK
        timestamp reading_ts
        float temperature
        float humidity
        float pressure
        float battery_pct
        float co2_level
        float latitude
        float longitude
        string firmware_version
        timestamp loaded_at
        string source_file
    }

    INT_READINGS_VALIDATED {
        string reading_id PK
        boolean is_temperature_valid
        boolean is_humidity_valid
        boolean is_pressure_valid
        boolean is_battery_valid
        boolean is_co2_valid
        boolean is_anomaly
        float temperature_zscore
        int validation_error_count
    }

    DIM_DEVICES {
        string device_key PK "Surrogate key"
        string device_id "Natural key"
        string device_type
        string cluster_id
        string firmware_version
        timestamp valid_from "SCD2"
        timestamp valid_to "SCD2"
    }

    FCT_HOURLY_READINGS {
        string hourly_reading_id PK
        string device_id FK
        timestamp reading_hour
        float avg_temperature
        float avg_humidity
        float avg_pressure
        float avg_co2_level
        int reading_count
        int anomaly_count
    }

    FCT_ANOMALIES {
        string anomaly_id PK
        string device_id FK
        timestamp detected_at
        string anomaly_type
        string sensor_type
        float observed_value
        string severity
    }

    RAW_SENSOR_READINGS ||--o{ STG_SENSOR_READINGS : "parsed"
    STG_SENSOR_READINGS ||--o{ INT_READINGS_VALIDATED : "validated"
    INT_READINGS_VALIDATED ||--o{ FCT_HOURLY_READINGS : "aggregated"
    INT_READINGS_VALIDATED ||--o{ FCT_ANOMALIES : "anomalies"
    DIM_DEVICES ||--o{ FCT_HOURLY_READINGS : "joined"
```

## Data Lineage

```mermaid
graph LR
    S3[S3 Raw JSON] --> RAW[raw.sensor_readings]
    SEED1[seed: device_registry] --> DIM[marts.dim_devices]
    SEED2[seed: sensor_thresholds] --> VAL[int.readings_validated]

    RAW --> STG[stg.sensor_readings]
    STG --> DEDUP[int.readings_deduped]
    DEDUP --> VAL
    VAL --> ENRICH[int.readings_enriched]
    VAL --> QUAR[int.quarantined_readings]
    ENRICH --> FCT_HR[marts.fct_hourly_readings]
    ENRICH --> FCT_HEALTH[marts.fct_device_health]
    VAL --> FCT_ANOM[marts.fct_anomalies]
    STG --> FCT_DQ[marts.fct_data_quality]
    FCT_HEALTH --> RPT[marts.rpt_fleet_overview]
    FCT_DQ --> RPT

    style S3 fill:#ff9900,color:#000
    style RAW fill:#29b5e8,color:#000
    style STG fill:#29b5e8,color:#000
    style DEDUP fill:#9b59b6,color:#fff
    style VAL fill:#9b59b6,color:#fff
    style ENRICH fill:#9b59b6,color:#fff
    style QUAR fill:#e74c3c,color:#fff
    style DIM fill:#2ecc71,color:#000
    style FCT_HR fill:#2ecc71,color:#000
    style FCT_HEALTH fill:#2ecc71,color:#000
    style FCT_ANOM fill:#2ecc71,color:#000
    style FCT_DQ fill:#2ecc71,color:#000
    style RPT fill:#f39c12,color:#000
    style SEED1 fill:#95a5a6,color:#000
    style SEED2 fill:#95a5a6,color:#000
```

**Colors**: Orange=S3, Blue=Raw/Staging, Purple=Intermediate, Red=Quarantine, Green=Marts, Yellow=Reports, Gray=Seeds

## Storage by Layer

| Layer | Format | Location | Why |
|-------|--------|----------|-----|
| Landing | JSON | S3 | Simple, fast writes from Lambda |
| Raw | VARIANT | Snowflake internal | Preserve original payload |
| Staging–Intermediate | Snowflake tables | Snowflake internal | Fast joins |
| Marts | Iceberg (Parquet) | S3 | Open format, portable, time travel |

## Technology Versions

| Technology | Version |
|-----------|---------|
| Python | 3.11 |
| Apache Airflow | 3.1.3 |
| dbt-core + dbt-snowflake | latest |
| Pydantic | v2 |
| sqlfluff + ruff | latest |

## Error Profiles

| Profile | Nulls | Out-of-Range | Duplicates |
|---------|-------|-------------|------------|
| `none` | 0% | 0% | 0% |
| `normal` | 3% | 2% | 5% |
| `high` | 10% | 8% | 15% |
| `chaos` | 25% | 15% | 30% |
