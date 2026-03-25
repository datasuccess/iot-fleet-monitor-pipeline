"""Configuration for IoT sensor data generator."""

from dataclasses import dataclass

# --- S3 Configuration ---
S3_BUCKET = "iot-fleet-monitor-data"
S3_PREFIX = "sensor_readings"

# --- Fleet Configuration ---
DEVICE_COUNT = 50
READINGS_PER_BATCH = 50  # One reading per device per invocation

# --- Sensor Ranges (normal operating conditions) ---
SENSOR_RANGES = {
    "temperature": {"min": -20.0, "max": 60.0, "unit": "°C"},
    "humidity": {"min": 10.0, "max": 95.0, "unit": "%"},
    "pressure": {"min": 950.0, "max": 1050.0, "unit": "hPa"},
    "battery": {"min": 0.0, "max": 100.0, "unit": "%"},
}

# --- Random Walk Parameters ---
# step_size: max change per reading (5-minute interval)
RANDOM_WALK = {
    "temperature": {"step_size": 0.5, "mean_reversion": 0.05},
    "humidity": {"step_size": 1.0, "mean_reversion": 0.03},
    "pressure": {"step_size": 0.3, "mean_reversion": 0.02},
}

# Battery drains slowly, recharges at threshold
BATTERY_DRAIN_RATE = 0.1  # % per reading
BATTERY_RECHARGE_THRESHOLD = 10.0  # Recharge when below this %
BATTERY_RECHARGE_LEVEL = 95.0  # Recharge to this %

# GPS jitter radius in degrees (~100m)
GPS_JITTER = 0.001


@dataclass
class ErrorProfile:
    """Defines error injection rates for a profile."""

    name: str
    null_rate: float  # Probability of injecting a null value
    oor_rate: float  # Probability of out-of-range value
    duplicate_rate: float  # Probability of duplicating a reading
    late_arrival_rate: float  # Probability of backdating a reading
    schema_drift_rate: float  # Probability of adding/removing fields


ERROR_PROFILES = {
    "none": ErrorProfile(
        name="none",
        null_rate=0.0,
        oor_rate=0.0,
        duplicate_rate=0.0,
        late_arrival_rate=0.0,
        schema_drift_rate=0.0,
    ),
    "normal": ErrorProfile(
        name="normal",
        null_rate=0.03,
        oor_rate=0.02,
        duplicate_rate=0.05,
        late_arrival_rate=0.02,
        schema_drift_rate=0.01,
    ),
    "high": ErrorProfile(
        name="high",
        null_rate=0.10,
        oor_rate=0.08,
        duplicate_rate=0.15,
        late_arrival_rate=0.05,
        schema_drift_rate=0.03,
    ),
    "chaos": ErrorProfile(
        name="chaos",
        null_rate=0.25,
        oor_rate=0.15,
        duplicate_rate=0.30,
        late_arrival_rate=0.10,
        schema_drift_rate=0.08,
    ),
}
