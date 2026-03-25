"""AWS Lambda handler — generates IoT sensor data and writes to S3."""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3

from data_generator.config import (
    ERROR_PROFILES,
    S3_BUCKET,
    S3_PREFIX,
)
from data_generator.devices import CLUSTERS, FLEET
from data_generator.errors import apply_error_profile
from data_generator.sensors import DeviceState

# Cache device states between warm Lambda invocations
_device_states: dict[str, DeviceState] = {}


def _get_device_state(device) -> DeviceState:
    """Get or initialize device state for random walk continuity."""
    if device.device_id not in _device_states:
        cluster = CLUSTERS[device.cluster_id]
        _device_states[device.device_id] = DeviceState(
            temperature=cluster["temp_baseline"],
            humidity=cluster["humidity_baseline"],
            pressure=1013.0,
            battery=100.0,
            base_lat=device.base_latitude,
            base_lon=device.base_longitude,
        )
    return _device_states[device.device_id]


def generate_batch(
    reading_ts: datetime, error_profile_name: str = "none"
) -> list[dict]:
    """Generate one batch of readings for all 50 devices."""
    profile = ERROR_PROFILES[error_profile_name]
    readings = []

    for device in FLEET:
        state = _get_device_state(device)
        sensor_data = state.generate_reading()

        reading = {
            "reading_id": str(uuid.uuid4()),
            "device_id": device.device_id,
            "reading_ts": reading_ts.isoformat(),
            "firmware_version": device.firmware_version,
            "error_profile": error_profile_name,
            **sensor_data,
        }
        readings.append(reading)

    # Apply error injection
    readings = apply_error_profile(readings, profile)

    return readings


def _s3_key(reading_ts: datetime) -> str:
    """Build partitioned S3 key."""
    ts_str = reading_ts.strftime("%Y%m%d_%H%M%S")
    return (
        f"{S3_PREFIX}/"
        f"year={reading_ts.year}/"
        f"month={reading_ts.month:02d}/"
        f"day={reading_ts.day:02d}/"
        f"hour={reading_ts.hour:02d}/"
        f"batch_{ts_str}.json"
    )


def lambda_handler(event, context):
    """AWS Lambda entry point.

    Event parameters:
        error_profile (str): One of 'none', 'normal', 'high', 'chaos'
        reading_ts (str): ISO timestamp override (optional, defaults to now)
    """
    error_profile = event.get("error_profile", "none")
    if error_profile not in ERROR_PROFILES:
        return {
            "statusCode": 400,
            "body": f"Invalid error_profile: {error_profile}. "
            f"Valid: {list(ERROR_PROFILES.keys())}",
        }

    ts_override = event.get("reading_ts")
    if ts_override:
        reading_ts = datetime.fromisoformat(ts_override)
    else:
        reading_ts = datetime.now(timezone.utc)

    # Generate readings
    readings = generate_batch(reading_ts, error_profile)

    # Write to S3
    bucket = os.environ.get("S3_BUCKET", S3_BUCKET)
    s3_key = _s3_key(reading_ts)

    s3 = boto3.client("s3")
    s3.put_object(
        Bucket=bucket,
        Key=s3_key,
        Body=json.dumps(readings, default=str),
        ContentType="application/json",
    )

    return {
        "statusCode": 200,
        "body": {
            "message": f"Generated {len(readings)} readings",
            "s3_path": f"s3://{bucket}/{s3_key}",
            "error_profile": error_profile,
            "reading_ts": reading_ts.isoformat(),
            "reading_count": len(readings),
        },
    }
