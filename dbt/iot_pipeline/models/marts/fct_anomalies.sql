{{
    config(
        materialized='incremental',
        unique_key='anomaly_id',
        incremental_strategy='merge'
    )
}}

/*
    Anomaly event log.
    Records each detected anomaly with classification and severity.
*/

with validated as (
    select * from {{ ref('int_readings_validated') }}
    where is_anomaly = true
       or not is_temperature_valid
       or not is_humidity_valid
       or not is_pressure_valid
       or not is_battery_valid
       or not is_co2_valid
    {% if is_incremental() %}
    and loaded_at > (select max(detected_at) from {{ this }})
    {% endif %}
),

thresholds as (
    select * from {{ ref('sensor_thresholds') }}
),

anomalies as (
    -- Temperature anomalies
    select
        {{ dbt_utils.generate_surrogate_key(['reading_id', "'temperature'"]) }} as anomaly_id,
        device_id,
        reading_ts as detected_at,
        case
            when abs(temperature_zscore) > 3 then 'zscore'
            else 'out_of_range'
        end as anomaly_type,
        'temperature' as sensor_type,
        temperature as observed_value,
        t.min_valid as expected_min,
        t.max_valid as expected_max,
        temperature_zscore as zscore,
        case
            when temperature < t.critical_low or temperature > t.critical_high then 'critical'
            when temperature < t.warning_low or temperature > t.warning_high then 'warning'
            else 'info'
        end as severity
    from validated v
    left join thresholds t on t.sensor_type = 'temperature'
    where not is_temperature_valid or (is_anomaly and temperature is not null)

    union all

    -- Humidity anomalies
    select
        {{ dbt_utils.generate_surrogate_key(['reading_id', "'humidity'"]) }} as anomaly_id,
        device_id,
        reading_ts as detected_at,
        'out_of_range' as anomaly_type,
        'humidity' as sensor_type,
        humidity as observed_value,
        t.min_valid as expected_min,
        t.max_valid as expected_max,
        null as zscore,
        case
            when humidity < t.critical_low or humidity > t.critical_high then 'critical'
            else 'warning'
        end as severity
    from validated v
    left join thresholds t on t.sensor_type = 'humidity'
    where not is_humidity_valid

    union all

    -- Pressure anomalies
    select
        {{ dbt_utils.generate_surrogate_key(['reading_id', "'pressure'"]) }} as anomaly_id,
        device_id,
        reading_ts as detected_at,
        'out_of_range' as anomaly_type,
        'pressure' as sensor_type,
        pressure as observed_value,
        t.min_valid as expected_min,
        t.max_valid as expected_max,
        null as zscore,
        case
            when pressure < t.critical_low or pressure > t.critical_high then 'critical'
            else 'warning'
        end as severity
    from validated v
    left join thresholds t on t.sensor_type = 'pressure'
    where not is_pressure_valid

    union all

    -- Battery anomalies
    select
        {{ dbt_utils.generate_surrogate_key(['reading_id', "'battery'"]) }} as anomaly_id,
        device_id,
        reading_ts as detected_at,
        'out_of_range' as anomaly_type,
        'battery' as sensor_type,
        battery_pct as observed_value,
        t.min_valid as expected_min,
        t.max_valid as expected_max,
        null as zscore,
        case
            when battery_pct < t.critical_low then 'critical'
            else 'warning'
        end as severity
    from validated v
    left join thresholds t on t.sensor_type = 'battery'
    where not is_battery_valid

    union all

    -- CO2 anomalies
    select
        {{ dbt_utils.generate_surrogate_key(['reading_id', "'co2'"]) }} as anomaly_id,
        device_id,
        reading_ts as detected_at,
        'out_of_range' as anomaly_type,
        'co2' as sensor_type,
        co2_level as observed_value,
        t.min_valid as expected_min,
        t.max_valid as expected_max,
        null as zscore,
        case
            when co2_level < t.critical_low or co2_level > t.critical_high then 'critical'
            else 'warning'
        end as severity
    from validated v
    left join thresholds t on t.sensor_type = 'co2'
    where not is_co2_valid
)

select * from anomalies
