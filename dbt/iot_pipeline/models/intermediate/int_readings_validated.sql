{{
    config(
        materialized='incremental',
        unique_key='reading_id',
        incremental_strategy='merge'
    )
}}

/*
    Validate sensor readings against thresholds and flag anomalies.
    - Range checks: compare against sensor_thresholds seed
    - Z-score anomaly detection: flag readings > 3 stddev from rolling mean
    - Counts total validation errors per reading
*/

with deduped as (
    select * from {{ ref('int_readings_deduped') }}
    {% if is_incremental() %}
    where loaded_at > (select max(loaded_at) from {{ this }})
    {% endif %}
),

thresholds as (
    select * from {{ ref('sensor_thresholds') }}
),

with_range_checks as (
    select
        d.*,

        -- Temperature range check
        case
            when d.temperature is null then false
            when d.temperature between t_temp.min_valid and t_temp.max_valid then true
            else false
        end as is_temperature_valid,

        -- Humidity range check
        case
            when d.humidity is null then false
            when d.humidity between t_hum.min_valid and t_hum.max_valid then true
            else false
        end as is_humidity_valid,

        -- Pressure range check
        case
            when d.pressure is null then false
            when d.pressure between t_pres.min_valid and t_pres.max_valid then true
            else false
        end as is_pressure_valid,

        -- Battery range check
        case
            when d.battery_pct is null then false
            when d.battery_pct between t_bat.min_valid and t_bat.max_valid then true
            else false
        end as is_battery_valid,

        -- CO2 range check (NULL = no sensor, which is valid)
        case
            when d.co2_level is null then true
            when d.co2_level between t_co2.min_valid and t_co2.max_valid then true
            else false
        end as is_co2_valid

    from deduped d
    left join thresholds t_temp on t_temp.sensor_type = 'temperature'
    left join thresholds t_hum on t_hum.sensor_type = 'humidity'
    left join thresholds t_pres on t_pres.sensor_type = 'pressure'
    left join thresholds t_bat on t_bat.sensor_type = 'battery'
    left join thresholds t_co2 on t_co2.sensor_type = 'co2'
),

with_zscores as (
    select
        *,

        -- Z-score: how many stddevs from the device's rolling average
        case
            when temperature is not null then
                (temperature - avg(temperature) over (
                    partition by device_id
                    order by reading_ts
                    rows between 12 preceding and current row
                )) / nullif(stddev(temperature) over (
                    partition by device_id
                    order by reading_ts
                    rows between 12 preceding and current row
                ), 0)
            else null
        end as temperature_zscore,

        -- Anomaly flag: z-score > 3 or any range check fails
        case
            when abs(
                (temperature - avg(temperature) over (
                    partition by device_id
                    order by reading_ts
                    rows between 12 preceding and current row
                )) / nullif(stddev(temperature) over (
                    partition by device_id
                    order by reading_ts
                    rows between 12 preceding and current row
                ), 0)
            ) > 3 then true
            else false
        end as is_anomaly

    from with_range_checks
),

final as (
    select
        *,
        -- Count total validation errors
        (case when not is_temperature_valid then 1 else 0 end
         + case when not is_humidity_valid then 1 else 0 end
         + case when not is_pressure_valid then 1 else 0 end
         + case when not is_battery_valid then 1 else 0 end
         + case when not is_co2_valid then 1 else 0 end
         + case when is_anomaly then 1 else 0 end
        ) as validation_error_count
    from with_zscores
)

select * from final
