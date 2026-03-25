"""Pydantic models for IoT sensor readings."""

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class SensorReading(BaseModel):
    """A single sensor reading from an IoT device."""

    reading_id: str = Field(description="Unique reading identifier (UUID)")
    device_id: str = Field(description="Device identifier (e.g., DEV_001)")
    reading_ts: datetime = Field(description="Timestamp of the reading")
    temperature: Optional[float] = Field(default=None, description="Temperature in °C")
    humidity: Optional[float] = Field(default=None, description="Relative humidity in %")
    pressure: Optional[float] = Field(default=None, description="Atmospheric pressure in hPa")
    battery_pct: Optional[float] = Field(default=None, description="Battery percentage")
    latitude: Optional[float] = Field(default=None, description="GPS latitude")
    longitude: Optional[float] = Field(default=None, description="GPS longitude")
    firmware_version: str = Field(description="Device firmware version")
    error_profile: str = Field(description="Error profile used for this batch")


class DeviceConfig(BaseModel):
    """Configuration for a single IoT device."""

    device_id: str
    device_name: str
    device_type: str  # Type A, B, or C
    cluster_id: str
    base_latitude: float
    base_longitude: float
    install_date: str
    firmware_version: str

    # Mutable state for random walk (not serialized to output)
    _current_temperature: float = 22.0
    _current_humidity: float = 50.0
    _current_pressure: float = 1013.0
    _current_battery: float = 100.0
