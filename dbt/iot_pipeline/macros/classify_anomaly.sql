{% macro classify_anomaly(value, sensor_type, thresholds_ref) %}
/*
    Classifies an anomaly severity based on sensor thresholds.
    Returns 'critical', 'warning', or 'normal'.

    Usage:
        {{ classify_anomaly('temperature', "'temperature'", ref('sensor_thresholds')) }}
*/
case
    when {{ value }} < (select critical_low from {{ thresholds_ref }} where sensor_type = {{ sensor_type }})
      or {{ value }} > (select critical_high from {{ thresholds_ref }} where sensor_type = {{ sensor_type }})
    then 'critical'
    when {{ value }} < (select warning_low from {{ thresholds_ref }} where sensor_type = {{ sensor_type }})
      or {{ value }} > (select warning_high from {{ thresholds_ref }} where sensor_type = {{ sensor_type }})
    then 'warning'
    else 'normal'
end
{% endmacro %}
