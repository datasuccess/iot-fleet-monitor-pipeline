"""50-device fleet registry organized in 5 geographic clusters."""

from data_generator.models import DeviceConfig

# --- Cluster Definitions ---
CLUSTERS = {
    "FACTORY_A": {
        "location": "New York, NY",
        "latitude": 40.7128,
        "longitude": -74.0060,
        "environment": "indoor_stable",
        "temp_baseline": 22.0,
        "humidity_baseline": 45.0,
    },
    "FACTORY_B": {
        "location": "Los Angeles, CA",
        "latitude": 34.0522,
        "longitude": -118.2437,
        "environment": "indoor_warm",
        "temp_baseline": 26.0,
        "humidity_baseline": 40.0,
    },
    "WAREHOUSE_A": {
        "location": "Chicago, IL",
        "latitude": 41.8781,
        "longitude": -87.6298,
        "environment": "semi_outdoor",
        "temp_baseline": 15.0,
        "humidity_baseline": 55.0,
    },
    "WAREHOUSE_B": {
        "location": "Houston, TX",
        "latitude": 29.7604,
        "longitude": -95.3698,
        "environment": "semi_outdoor_humid",
        "temp_baseline": 30.0,
        "humidity_baseline": 70.0,
    },
    "OUTDOOR": {
        "location": "Seattle, WA",
        "latitude": 47.6062,
        "longitude": -122.3321,
        "environment": "outdoor",
        "temp_baseline": 12.0,
        "humidity_baseline": 75.0,
    },
}

# Device type determines sensor hardware characteristics
DEVICE_TYPES = ["Type_A", "Type_B", "Type_C"]
FIRMWARE_VERSIONS = ["1.0.0", "1.1.0", "1.2.0", "2.0.0"]


def _build_fleet() -> list[DeviceConfig]:
    """Build the 50-device fleet registry."""
    devices = []
    cluster_names = list(CLUSTERS.keys())

    for i in range(1, 51):
        cluster_idx = (i - 1) // 10  # 10 devices per cluster
        cluster_id = cluster_names[cluster_idx]
        cluster = CLUSTERS[cluster_id]

        device_type = DEVICE_TYPES[i % len(DEVICE_TYPES)]
        firmware = FIRMWARE_VERSIONS[i % len(FIRMWARE_VERSIONS)]

        device = DeviceConfig(
            device_id=f"DEV_{i:03d}",
            device_name=f"Sensor {cluster_id.lower()}_{i:03d}",
            device_type=device_type,
            cluster_id=cluster_id,
            base_latitude=cluster["latitude"],
            base_longitude=cluster["longitude"],
            install_date="2025-01-15" if i <= 30 else "2025-06-01",
            firmware_version=firmware,
        )
        devices.append(device)

    return devices


FLEET: list[DeviceConfig] = _build_fleet()
FLEET_MAP: dict[str, DeviceConfig] = {d.device_id: d for d in FLEET}
