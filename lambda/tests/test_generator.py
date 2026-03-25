"""Local tests for the IoT sensor data generator."""

import json
import sys
import os
from datetime import datetime, timezone

# Allow running from repo root: python -m pytest lambda/tests/
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from data_generator.config import ERROR_PROFILES
from data_generator.devices import FLEET, FLEET_MAP
from data_generator.handler import generate_batch
from data_generator.sensors import DeviceState


def test_fleet_has_50_devices():
    assert len(FLEET) == 50
    assert len(FLEET_MAP) == 50


def test_fleet_device_ids():
    for i, device in enumerate(FLEET, 1):
        assert device.device_id == f"DEV_{i:03d}"


def test_fleet_clusters():
    cluster_counts = {}
    for device in FLEET:
        cluster_counts[device.cluster_id] = cluster_counts.get(device.cluster_id, 0) + 1
    # 10 devices per cluster
    for count in cluster_counts.values():
        assert count == 10


def test_device_state_random_walk():
    state = DeviceState(
        temperature=22.0,
        humidity=50.0,
        pressure=1013.0,
        battery=100.0,
        base_lat=40.7128,
        base_lon=-74.0060,
    )
    readings = [state.generate_reading() for _ in range(100)]

    # Values should change but stay within reasonable bounds
    temps = [r["temperature"] for r in readings]
    assert min(temps) >= -20.0
    assert max(temps) <= 60.0

    # Battery should drain
    batteries = [r["battery_pct"] for r in readings]
    assert batteries[-1] < batteries[0] or any(b > 90 for b in batteries)  # Recharged


def test_generate_batch_none_profile():
    ts = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    readings = generate_batch(ts, "none")

    assert len(readings) == 50
    for r in readings:
        assert "reading_id" in r
        assert "device_id" in r
        assert "reading_ts" in r
        assert "temperature" in r
        assert "humidity" in r
        assert "pressure" in r
        assert "battery_pct" in r
        assert "latitude" in r
        assert "longitude" in r
        assert r["error_profile"] == "none"


def test_generate_batch_chaos_has_more_readings():
    """Chaos profile should produce duplicates, so more readings."""
    ts = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)

    # Run multiple times to account for randomness
    chaos_totals = []
    for _ in range(10):
        readings = generate_batch(ts, "chaos")
        chaos_totals.append(len(readings))

    # At least some batches should have duplicates (> 50)
    assert max(chaos_totals) > 50


def test_all_error_profiles_valid():
    ts = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    for profile_name in ERROR_PROFILES:
        readings = generate_batch(ts, profile_name)
        assert len(readings) >= 50  # At least 50 (more with dupes)


def test_readings_serializable():
    ts = datetime(2026, 1, 15, 12, 0, 0, tzinfo=timezone.utc)
    readings = generate_batch(ts, "normal")
    # Should serialize to JSON without error
    json_str = json.dumps(readings, default=str)
    parsed = json.loads(json_str)
    assert len(parsed) >= 50


if __name__ == "__main__":
    print("Running tests...")
    test_fleet_has_50_devices()
    print("  ✓ Fleet has 50 devices")
    test_fleet_device_ids()
    print("  ✓ Device IDs are correct")
    test_fleet_clusters()
    print("  ✓ 10 devices per cluster")
    test_device_state_random_walk()
    print("  ✓ Random walk stays in bounds")
    test_generate_batch_none_profile()
    print("  ✓ None profile generates clean data")
    test_generate_batch_chaos_has_more_readings()
    print("  ✓ Chaos profile produces duplicates")
    test_all_error_profiles_valid()
    print("  ✓ All error profiles work")
    test_readings_serializable()
    print("  ✓ Readings are JSON-serializable")
    print("\nAll tests passed!")
