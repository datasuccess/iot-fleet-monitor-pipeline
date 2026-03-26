"""Data models for IoT sensor readings — plain dataclasses (no external deps)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class SensorReading:
    """A single sensor reading from an IoT device."""

    reading_id: str
    device_id: str
    reading_ts: str  # ISO format timestamp
    temperature: Optional[float] = None
    humidity: Optional[float] = None
    pressure: Optional[float] = None
    battery_pct: Optional[float] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    firmware_version: str = ""
    error_profile: str = ""


@dataclass
class DeviceConfig:
    """Configuration for a single IoT device."""

    device_id: str
    device_name: str
    device_type: str  # Type A, B, or C
    cluster_id: str
    base_latitude: float
    base_longitude: float
    install_date: str
    firmware_version: str
