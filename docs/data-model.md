# Data Model — IoT Fleet Monitor Pipeline

## Entity Relationship Diagram

```mermaid
erDiagram
    RAW_SENSOR_READINGS {
        variant raw_data "Entire JSON payload"
        timestamp loaded_at "When COPY INTO ran"
        string source_file "S3 file path"
    }

    STG_SENSOR_READINGS {
        string reading_id PK "Unique reading identifier"
        string device_id FK "References device"
        timestamp reading_ts "When reading was taken"
        float temperature "°C"
        float humidity "%"
        float pressure "hPa"
        float battery_pct "%"
        float latitude "GPS lat"
        float longitude "GPS lon"
        string firmware_version "Device firmware"
        timestamp loaded_at "Ingestion timestamp"
        string source_file "Origin S3 file"
    }

    STG_DEVICE_METADATA {
        string device_id PK "Unique device ID"
        string device_type "Type A, B, or C"
        string cluster_id FK "Deployment cluster"
        string firmware_version "Current firmware"
        date install_date "When deployed"
        string status "active / maintenance / retired"
    }

    DEVICE_REGISTRY {
        string device_id PK "Seed: DEV_001–DEV_050"
        string device_name "Human-readable name"
        string device_type "Type A, B, or C"
        string cluster_id "FACTORY_A, WAREHOUSE_B, etc."
        float base_latitude "Cluster center lat"
        float base_longitude "Cluster center lon"
        date install_date "Deployment date"
    }

    SENSOR_THRESHOLDS {
        string sensor_type PK "temperature, humidity, etc."
        float min_valid "Lower bound"
        float max_valid "Upper bound"
        float warning_low "Warning threshold low"
        float warning_high "Warning threshold high"
        float critical_low "Critical threshold low"
        float critical_high "Critical threshold high"
    }

    INT_READINGS_DEDUPED {
        string reading_id PK
        string device_id FK
        timestamp reading_ts
        float temperature
        float humidity
        float pressure
        float battery_pct
        float latitude
        float longitude
        int row_number "Dedup rank"
    }

    INT_READINGS_VALIDATED {
        string reading_id PK
        string device_id FK
        timestamp reading_ts
        float temperature
        float humidity
        float pressure
        float battery_pct
        boolean is_temperature_valid
        boolean is_humidity_valid
        boolean is_pressure_valid
        boolean is_battery_valid
        boolean is_anomaly "Z-score flagged"
        float temperature_zscore
        int validation_error_count
    }

    INT_READINGS_ENRICHED {
        string reading_id PK
        string device_id FK
        timestamp reading_ts
        float temperature
        float humidity
        float pressure
        float battery_pct
        string device_type "From device metadata"
        string cluster_id "From device metadata"
        int hour_of_day "0–23"
        string day_of_week "Monday–Sunday"
        boolean is_weekend
        boolean is_business_hours
    }

    INT_QUARANTINED_READINGS {
        string reading_id PK
        string device_id FK
        timestamp reading_ts
        variant raw_data "Original payload"
        array rejection_reasons "List of reason codes"
        timestamp quarantined_at
    }

    INT_LATE_ARRIVING_READINGS {
        string reading_id PK
        string device_id FK
        timestamp reading_ts
        timestamp loaded_at
        float arrival_delay_minutes "How late"
    }

    DIM_DEVICES {
        string device_key PK "Surrogate key"
        string device_id "Natural key"
        string device_name
        string device_type
        string cluster_id
        string firmware_version
        string status
        date install_date
        timestamp valid_from "SCD2"
        timestamp valid_to "SCD2"
        boolean is_current "SCD2"
    }

    FCT_HOURLY_READINGS {
        string hourly_reading_id PK
        string device_id FK
        timestamp reading_hour "Truncated to hour"
        float avg_temperature
        float min_temperature
        float max_temperature
        float stddev_temperature
        float avg_humidity
        float avg_pressure
        float avg_battery_pct
        int reading_count
        int anomaly_count
    }

    FCT_DEVICE_HEALTH {
        string device_health_id PK
        string device_id FK
        date report_date
        float avg_battery_pct
        float battery_drain_rate "% per hour"
        float uptime_pct "Readings received / expected"
        int readings_received
        int readings_expected
        string health_status "healthy / warning / critical"
        int alert_count
    }

    FCT_ANOMALIES {
        string anomaly_id PK
        string device_id FK
        timestamp detected_at
        string anomaly_type "zscore / out_of_range / spike / flatline"
        string sensor_type "temperature / humidity / etc."
        float observed_value
        float expected_min
        float expected_max
        float zscore
        string severity "warning / critical"
    }

    FCT_DATA_QUALITY {
        string quality_id PK
        timestamp batch_ts
        string source_file
        int total_records
        int null_count
        float null_pct
        int oor_count "Out of range"
        float oor_pct
        int duplicate_count
        float duplicate_pct
        int quarantined_count
        int late_arrival_count
        float quality_score "0–100"
    }

    RPT_FLEET_OVERVIEW {
        date report_date PK
        int active_devices
        int total_readings
        float avg_quality_score
        int critical_alerts
        int warning_alerts
        int devices_low_battery
        int devices_offline
        float fleet_uptime_pct
        string top_issue
    }

    RAW_SENSOR_READINGS ||--o{ STG_SENSOR_READINGS : "parsed into"
    STG_SENSOR_READINGS ||--o{ INT_READINGS_DEDUPED : "deduplicated"
    INT_READINGS_DEDUPED ||--o{ INT_READINGS_VALIDATED : "validated"
    INT_READINGS_VALIDATED ||--o{ INT_READINGS_ENRICHED : "enriched"
    INT_READINGS_VALIDATED ||--o{ INT_QUARANTINED_READINGS : "quarantined if bad"
    STG_SENSOR_READINGS ||--o{ INT_LATE_ARRIVING_READINGS : "late arrivals"
    DEVICE_REGISTRY ||--|| DIM_DEVICES : "seed + snapshot"
    STG_DEVICE_METADATA ||--|| DIM_DEVICES : "metadata source"
    SENSOR_THRESHOLDS ||--o{ INT_READINGS_VALIDATED : "range checks"
    DIM_DEVICES ||--o{ INT_READINGS_ENRICHED : "joined"
    INT_READINGS_ENRICHED ||--o{ FCT_HOURLY_READINGS : "aggregated"
    INT_READINGS_ENRICHED ||--o{ FCT_DEVICE_HEALTH : "health metrics"
    INT_READINGS_VALIDATED ||--o{ FCT_ANOMALIES : "anomalies logged"
    STG_SENSOR_READINGS ||--o{ FCT_DATA_QUALITY : "quality scored"
    FCT_DEVICE_HEALTH ||--o{ RPT_FLEET_OVERVIEW : "summarized"
    FCT_DATA_QUALITY ||--o{ RPT_FLEET_OVERVIEW : "summarized"
```

## Data Lineage (DAG)

```mermaid
graph LR
    S3[S3 Raw JSON] --> RAW[raw.sensor_readings]
    SEED1[seed: device_registry] --> DIM[marts.dim_devices]
    SEED2[seed: sensor_thresholds] --> VAL[int.readings_validated]

    RAW --> STG[stg.sensor_readings]
    RAW --> STG_DEV[stg.device_metadata]

    STG --> DEDUP[int.readings_deduped]
    DEDUP --> VAL
    VAL --> ENRICH[int.readings_enriched]
    VAL --> QUAR[int.quarantined_readings]
    STG --> LATE[int.late_arriving_readings]

    STG_DEV --> DIM
    ENRICH --> FCT_HR[marts.fct_hourly_readings]
    ENRICH --> FCT_HEALTH[marts.fct_device_health]
    VAL --> FCT_ANOM[marts.fct_anomalies]
    STG --> FCT_DQ[marts.fct_data_quality]
    FCT_HEALTH --> RPT[marts.rpt_fleet_overview]
    FCT_DQ --> RPT

    style S3 fill:#ff9900,color:#000
    style RAW fill:#29b5e8,color:#000
    style STG fill:#29b5e8,color:#000
    style STG_DEV fill:#29b5e8,color:#000
    style DEDUP fill:#9b59b6,color:#fff
    style VAL fill:#9b59b6,color:#fff
    style ENRICH fill:#9b59b6,color:#fff
    style QUAR fill:#e74c3c,color:#fff
    style LATE fill:#e74c3c,color:#fff
    style DIM fill:#2ecc71,color:#000
    style FCT_HR fill:#2ecc71,color:#000
    style FCT_HEALTH fill:#2ecc71,color:#000
    style FCT_ANOM fill:#2ecc71,color:#000
    style FCT_DQ fill:#2ecc71,color:#000
    style RPT fill:#f39c12,color:#000
    style SEED1 fill:#95a5a6,color:#000
    style SEED2 fill:#95a5a6,color:#000
```

### Color Legend
- **Orange**: External source (S3)
- **Blue**: Raw / Staging layer
- **Purple**: Intermediate layer
- **Red**: Quarantine / Late arrivals
- **Green**: Mart layer (Iceberg tables)
- **Yellow**: Reporting
- **Gray**: Seeds (reference data)

## Storage Format by Layer

| Layer | Format | Location | Why |
|-------|--------|----------|-----|
| Landing | JSON | S3 `sensor_readings/` | Simple, fast writes from Lambda |
| Raw | VARIANT | Snowflake internal | Preserve original payload exactly |
| Staging–Intermediate | Snowflake tables | Snowflake internal | Fast joins, transformations |
| Marts | Apache Iceberg (Parquet) | S3 `iceberg/iot_pipeline/` | Open format, portable, time travel |

## Key Relationships

- Every **reading** comes from exactly one **device**
- Every **device** belongs to one **cluster**
- **Quarantined readings** reference the original reading but are stored separately
- **Anomalies** are derived from validated readings, one anomaly per (reading, sensor_type) combination
- **Hourly readings** aggregate from enriched readings, one row per (device, hour)
- **Device health** aggregates daily per device
- **Fleet overview** summarizes daily across entire fleet
- **dim_devices** tracks historical changes via SCD Type 2 (firmware updates, status changes)
