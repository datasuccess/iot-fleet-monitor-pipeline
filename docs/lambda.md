# Phase 1: Lambda Data Generator — Code Explained

## 1. Random Walk (sensors.py)

This is the most important concept. Instead of generating random values each time, we **drift** from the previous value:

```python
def _random_walk_step(self, current: float, sensor_type: str) -> float:
    # Mean reversion: pull toward center of range
    center = (limits["min"] + limits["max"]) / 2
    reversion = params["mean_reversion"] * (center - current)

    # Random step
    step = random.uniform(-params["step_size"], params["step_size"])

    new_value = current + step + reversion
```

**Why it matters**: Real sensors don't jump from 22°C to 55°C between readings. They drift slowly. This creates realistic time-series data.

Three forces at work:
- **current value** — where we are now
- **random step** — small random change (±0.5°C for temperature)
- **mean reversion** — gently pulls back toward the center so values don't drift to extremes forever

If temperature reaches 58°C, mean reversion pulls it back down. If it's at 20°C (center), reversion is near zero. This is how real physical systems behave.

---

## 2. Device State Persistence (handler.py)

```python
_device_states: dict[str, DeviceState] = {}
```

This dict lives **outside** the handler function. In Lambda, when the container stays warm between invocations, this state persists. So device DEV_001's temperature at 23.5°C in one invocation starts at 23.5°C in the next — maintaining the random walk continuity.

If Lambda cold-starts, devices reset to their cluster baselines. That's fine — it simulates a device reboot.

---

## 3. Error Injection (errors.py)

Five types of real-world data problems:

| Error | What it does | Real-world cause |
|-------|-------------|-----------------|
| **Nulls** | Sets sensor field to `None` | Sensor malfunction, timeout |
| **Out-of-range** | Value like 120°C temperature | Sensor hardware failure |
| **Duplicates** | Exact copy of a reading | Network retry, at-least-once delivery |
| **Late arrivals** | Backdates timestamp by 1-24 hours | Device was offline, synced later |
| **Schema drift** | Adds/removes/renames fields | Firmware update changed the payload |

The key design: errors are applied **after** generation. Clean data is generated first, then corrupted:

```python
readings = generate_batch(...)                      # Always clean first
readings = apply_error_profile(readings, profile)   # Then corrupt
```

This separation makes testing easy — `none` profile = clean data guaranteed.

---

## 4. S3 Hive-Style Partitioning (handler.py)

```python
f"{S3_PREFIX}/year={reading_ts.year}/month={reading_ts.month:02d}/day={reading_ts.day:02d}/hour={reading_ts.hour:02d}/batch_{ts_str}.json"
```

Instead of dumping all files in one folder, data is organized by time:

```
sensor_readings/
  year=2026/
    month=03/
      day=25/
        hour=14/
          batch_20260325_140000.json
        hour=15/
          batch_20260325_150000.json
```

**Why it matters**: When Snowflake loads data, it can target specific partitions. Loading "just today's data" scans one folder instead of thousands of files. This is called **partition pruning** and is critical at scale.

The `key=value` format (e.g., `year=2026`) is called **Hive-style** because Apache Hive popularized it. Most data tools (Snowflake, Spark, Athena, dbt) understand this format natively.

---

## 5. Pydantic Models (models.py)

```python
class SensorReading(BaseModel):
    reading_id: str
    temperature: Optional[float] = Field(default=None)
```

Pydantic gives you **runtime type validation**. If something passes a string where a float is expected, it raises an error immediately. `Optional[float]` allows `None` (which our null injection needs).

We define the model but generate readings as plain dicts in the handler — this is intentional. The model documents the schema and can be used for validation if needed, but dicts are faster for Lambda execution.

---

## 6. Configurable Error Profiles (config.py)

```python
@dataclass
class ErrorProfile:
    null_rate: float      # 0.0 to 1.0
    oor_rate: float       # 0.0 to 1.0
    duplicate_rate: float # 0.0 to 1.0
    ...
```

Four profiles with escalating error rates:

| Profile | Nulls | Out-of-Range | Duplicates | Use Case |
|---------|-------|-------------|------------|----------|
| `none` | 0% | 0% | 0% | Baseline testing |
| `normal` | 3% | 2% | 5% | Day-to-day simulation |
| `high` | 10% | 8% | 15% | Stress testing |
| `chaos` | 25% | 15% | 30% | Resilience testing |

The Lambda accepts `error_profile` as an input parameter:

```json
{"error_profile": "chaos"}
```

This means Airflow (Phase 6) can **choose the profile at runtime** — Day 1 runs `none`, Day 4 runs `chaos`, all with the same Lambda code.

---

## 7. Cluster-Based Device Fleet (devices.py)

50 devices split across 5 geographic clusters, 10 each:

| Cluster | Location | Environment | Temp Baseline |
|---------|----------|-------------|---------------|
| FACTORY_A | NYC | Indoor, stable | 22°C |
| FACTORY_B | LA | Indoor, warm | 26°C |
| WAREHOUSE_A | Chicago | Semi-outdoor | 15°C |
| WAREHOUSE_B | Houston | Semi-outdoor, humid | 30°C |
| OUTDOOR | Seattle | Outdoor | 12°C |

Each cluster has a different **baseline** for temperature and humidity. The random walk starts from these baselines, so factory sensors hover around 22°C while outdoor Seattle sensors hover around 12°C — just like reality.

---

## 8. Battery Simulation (sensors.py)

```python
self.battery -= BATTERY_DRAIN_RATE  # 0.1% per reading
if self.battery < BATTERY_RECHARGE_THRESHOLD:  # Below 10%
    self.battery = BATTERY_RECHARGE_LEVEL       # Recharge to 95%
```

Battery doesn't random-walk — it **drains steadily** (0.1% per 5-minute reading = ~8.3 hours to drain). When it hits 10%, it "recharges" to 95% (simulating a battery swap or solar recharge). This creates a realistic sawtooth pattern in the data that's useful for device health monitoring in Phase 5.

---

## File Flow Summary

```
config.py          → Defines ranges, walk params, error profiles
    ↓
devices.py         → Builds 50 devices with cluster baselines
    ↓
sensors.py         → Random walk engine, generates next reading from current state
    ↓
errors.py          → Corrupts clean readings based on selected profile
    ↓
handler.py         → Orchestrates: generate → inject errors → write JSON to S3
```
