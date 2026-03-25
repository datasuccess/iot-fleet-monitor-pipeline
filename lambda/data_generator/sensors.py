"""Time-series-aware sensor value generators using random walk."""

import random

from data_generator.config import (
    BATTERY_DRAIN_RATE,
    BATTERY_RECHARGE_LEVEL,
    BATTERY_RECHARGE_THRESHOLD,
    GPS_JITTER,
    RANDOM_WALK,
    SENSOR_RANGES,
)


class DeviceState:
    """Tracks the current state of a device's sensors for random walk continuity."""

    def __init__(
        self,
        temperature: float,
        humidity: float,
        pressure: float,
        battery: float,
        base_lat: float,
        base_lon: float,
    ):
        self.temperature = temperature
        self.humidity = humidity
        self.pressure = pressure
        self.battery = battery
        self.base_lat = base_lat
        self.base_lon = base_lon

    def _random_walk_step(self, current: float, sensor_type: str) -> float:
        """Apply one random walk step with mean reversion and clamping."""
        params = RANDOM_WALK[sensor_type]
        limits = SENSOR_RANGES[sensor_type]

        # Mean reversion: pull toward center of range
        center = (limits["min"] + limits["max"]) / 2
        reversion = params["mean_reversion"] * (center - current)

        # Random step
        step = random.uniform(-params["step_size"], params["step_size"])

        new_value = current + step + reversion

        # Clamp to valid range
        return max(limits["min"], min(limits["max"], new_value))

    def generate_reading(self) -> dict:
        """Generate the next reading based on current state."""
        # Random walk for temperature, humidity, pressure
        self.temperature = self._random_walk_step(self.temperature, "temperature")
        self.humidity = self._random_walk_step(self.humidity, "humidity")
        self.pressure = self._random_walk_step(self.pressure, "pressure")

        # Battery drains slowly, recharges at threshold
        self.battery -= BATTERY_DRAIN_RATE
        if self.battery < BATTERY_RECHARGE_THRESHOLD:
            self.battery = BATTERY_RECHARGE_LEVEL

        # GPS jitter around base location
        lat = self.base_lat + random.uniform(-GPS_JITTER, GPS_JITTER)
        lon = self.base_lon + random.uniform(-GPS_JITTER, GPS_JITTER)

        return {
            "temperature": round(self.temperature, 2),
            "humidity": round(self.humidity, 2),
            "pressure": round(self.pressure, 2),
            "battery_pct": round(max(0, self.battery), 2),
            "latitude": round(lat, 6),
            "longitude": round(lon, 6),
        }
