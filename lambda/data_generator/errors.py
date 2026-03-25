"""Configurable error injection for realistic data quality issues."""

import copy
import random
from datetime import timedelta

from data_generator.config import SENSOR_RANGES, ErrorProfile


SENSOR_FIELDS = ["temperature", "humidity", "pressure", "battery_pct"]


def inject_nulls(reading: dict, rate: float) -> dict:
    """Randomly set sensor fields to None."""
    for field in SENSOR_FIELDS:
        if random.random() < rate:
            reading[field] = None
    return reading


def inject_out_of_range(reading: dict, rate: float) -> dict:
    """Replace sensor values with out-of-range values."""
    oor_map = {
        "temperature": (-50.0, 120.0),
        "humidity": (-10.0, 150.0),
        "pressure": (800.0, 1200.0),
        "battery_pct": (-5.0, 110.0),
    }
    for field in SENSOR_FIELDS:
        if reading.get(field) is not None and random.random() < rate:
            low, high = oor_map[field]
            limits = SENSOR_RANGES.get(field.replace("_pct", ""), {})
            if random.random() < 0.5:
                # Below range
                reading[field] = round(random.uniform(low, limits.get("min", low)), 2)
            else:
                # Above range
                reading[field] = round(random.uniform(limits.get("max", high), high), 2)
    return reading


def inject_duplicates(readings: list[dict], rate: float) -> list[dict]:
    """Duplicate some readings (exact copies)."""
    duplicates = []
    for reading in readings:
        duplicates.append(reading)
        if random.random() < rate:
            dupe = copy.deepcopy(reading)
            duplicates.append(dupe)
    return duplicates


def inject_late_arrivals(reading: dict, rate: float) -> dict:
    """Backdate some readings to simulate late-arriving data."""
    if random.random() < rate:
        from datetime import datetime

        ts = datetime.fromisoformat(reading["reading_ts"])
        delay = timedelta(hours=random.randint(1, 24))
        reading["reading_ts"] = (ts - delay).isoformat()
    return reading


def inject_schema_drift(reading: dict, rate: float) -> dict:
    """Add unexpected fields or remove expected ones."""
    if random.random() < rate:
        action = random.choice(["add_field", "remove_field", "rename_field"])
        if action == "add_field":
            reading["signal_strength"] = round(random.uniform(-100, -30), 2)
        elif action == "remove_field":
            field = random.choice(SENSOR_FIELDS)
            reading.pop(field, None)
        elif action == "rename_field":
            if "temperature" in reading:
                reading["temp_celsius"] = reading.pop("temperature")
    return reading


def apply_error_profile(readings: list[dict], profile: ErrorProfile) -> list[dict]:
    """Apply all error injections based on the selected profile."""
    if profile.name == "none":
        return readings

    # Apply per-reading errors
    for i, reading in enumerate(readings):
        readings[i] = inject_nulls(reading, profile.null_rate)
        readings[i] = inject_out_of_range(reading, profile.oor_rate)
        readings[i] = inject_late_arrivals(reading, profile.late_arrival_rate)
        readings[i] = inject_schema_drift(reading, profile.schema_drift_rate)

    # Apply batch-level errors (duplicates)
    readings = inject_duplicates(readings, profile.duplicate_rate)

    return readings
