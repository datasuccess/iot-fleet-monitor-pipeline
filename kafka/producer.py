"""
Kafka Producer — Simulates real-time IoT sensor events.

Reuses the same data generator as Lambda, but instead of writing JSON to S3
once per hour, it sends individual readings to Kafka every few seconds.

BATCH (Lambda):     50 devices × 1 batch/hour → S3 file → COPY INTO (hourly)
STREAMING (Kafka):  50 devices × 1 reading/5sec → Kafka topic → Consumer (real-time)

Usage:
    python producer.py                    # Normal speed (1 batch every 5 seconds)
    python producer.py --fast             # Fast mode (1 batch every 0.5 seconds)
    python producer.py --device DEV_001   # Single device only
    python producer.py --error-profile high  # Inject errors
"""

import argparse
import json
import sys
import time
import uuid
from datetime import datetime, timezone

from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient

# ---------------------------------------------------------------------------
# Sensor simulation (simplified version of lambda/data_generator)
# ---------------------------------------------------------------------------

CLUSTERS = {
    "FACTORY_A":   {"lat": 40.7128, "lon": -74.006,   "temp": 22, "humidity": 55},
    "FACTORY_B":   {"lat": 34.0522, "lon": -118.2437, "temp": 28, "humidity": 40},
    "WAREHOUSE_A": {"lat": 41.8781, "lon": -87.6298,  "temp": 18, "humidity": 45},
    "WAREHOUSE_B": {"lat": 29.7604, "lon": -95.3698,  "temp": 32, "humidity": 65},
    "OUTDOOR":     {"lat": 47.6062, "lon": -122.3321, "temp": 12, "humidity": 70},
}

DEVICES = []
for cluster_id, info in CLUSTERS.items():
    for i in range(10):
        idx = len(DEVICES) + 1
        DEVICES.append({
            "device_id": f"DEV_{idx:03d}",
            "cluster_id": cluster_id,
            "device_type": ["Type_A", "Type_B", "Type_C"][i % 3],
            "lat": info["lat"],
            "lon": info["lon"],
            "temp_base": info["temp"],
            "humidity_base": info["humidity"],
        })

# Random walk state per device
import random
_device_state = {}


def _get_state(device_id, temp_base, humidity_base):
    if device_id not in _device_state:
        _device_state[device_id] = {
            "temp": temp_base + random.uniform(-2, 2),
            "humidity": humidity_base + random.uniform(-5, 5),
            "pressure": 1013.0 + random.uniform(-5, 5),
            "battery": 100.0 - random.uniform(0, 30),
        }
    return _device_state[device_id]


ERROR_PROFILES = {
    "none":   {"null_rate": 0.0,  "oor_rate": 0.0,  "dupe_rate": 0.0},
    "normal": {"null_rate": 0.03, "oor_rate": 0.02, "dupe_rate": 0.05},
    "high":   {"null_rate": 0.10, "oor_rate": 0.08, "dupe_rate": 0.15},
    "chaos":  {"null_rate": 0.25, "oor_rate": 0.15, "dupe_rate": 0.30},
}


def generate_reading(device: dict, error_profile: str = "none") -> dict:
    """Generate a single sensor reading with random walk."""
    state = _get_state(device["device_id"], device["temp_base"], device["humidity_base"])
    profile = ERROR_PROFILES[error_profile]

    # Random walk
    state["temp"] += random.gauss(0, 0.5)
    state["humidity"] = max(0, min(100, state["humidity"] + random.gauss(0, 1)))
    state["pressure"] += random.gauss(0, 0.2)
    state["battery"] = max(0, state["battery"] - random.uniform(0, 0.01))

    reading = {
        "reading_id": str(uuid.uuid4()),
        "device_id": device["device_id"],
        "reading_ts": datetime.now(timezone.utc).isoformat(),
        "cluster_id": device["cluster_id"],
        "device_type": device["device_type"],
        "firmware_version": "v2.1",
        "error_profile": error_profile,
        "temperature": round(state["temp"], 2),
        "humidity": round(state["humidity"], 2),
        "pressure": round(state["pressure"], 2),
        "battery_pct": round(state["battery"], 2),
        "latitude": round(device["lat"] + random.gauss(0, 0.001), 6),
        "longitude": round(device["lon"] + random.gauss(0, 0.001), 6),
    }

    # Error injection
    if random.random() < profile["null_rate"]:
        field = random.choice(["temperature", "humidity", "pressure"])
        reading[field] = None

    if random.random() < profile["oor_rate"]:
        reading["temperature"] = random.choice([-50, 120, 999])

    return reading


# ---------------------------------------------------------------------------
# Kafka Producer
# ---------------------------------------------------------------------------

def delivery_callback(err, msg):
    """Called once for each produced message to indicate delivery result."""
    if err:
        print(f"  FAILED: {err}")
    else:
        # msg.partition() and msg.offset() tell you exactly where the message landed
        print(f"  → topic={msg.topic()} partition={msg.partition()} offset={msg.offset()}")


def check_kafka_connection(bootstrap_servers: str) -> bool:
    """Verify Kafka is reachable before producing."""
    try:
        admin = AdminClient({"bootstrap.servers": bootstrap_servers})
        metadata = admin.list_topics(timeout=5)
        print(f"Connected to Kafka. Broker count: {len(metadata.brokers)}")
        print(f"Existing topics: {list(metadata.topics.keys())}")
        return True
    except Exception as e:
        print(f"Cannot connect to Kafka at {bootstrap_servers}: {e}")
        return False


def run_producer(
    bootstrap_servers: str = "localhost:9093",
    topic: str = "iot.sensor.readings",
    interval: float = 5.0,
    error_profile: str = "none",
    device_filter: str = None,
    max_batches: int = None,
):
    """
    Produce sensor readings to Kafka.

    Each "batch" generates one reading per device and sends them individually.
    With 50 devices and 5-second interval, that's 50 messages every 5 seconds
    = 600 messages/minute = 36,000 messages/hour.

    Compare to Lambda: 1 file with 50 readings per hour.
    """
    if not check_kafka_connection(bootstrap_servers):
        sys.exit(1)

    # Producer config
    conf = {
        "bootstrap.servers": bootstrap_servers,
        "client.id": "iot-sensor-producer",

        # Batching: collect messages for up to 100ms before sending (throughput vs latency)
        "linger.ms": 100,
        "batch.size": 65536,  # 64 KB batch

        # Reliability: wait for leader acknowledgment
        "acks": "all",

        # Compression: reduce network traffic
        "compression.type": "snappy",
    }

    producer = Producer(conf)

    devices = DEVICES
    if device_filter:
        devices = [d for d in DEVICES if d["device_id"] == device_filter]
        if not devices:
            print(f"Device {device_filter} not found")
            sys.exit(1)

    print(f"\nProducing to topic '{topic}'")
    print(f"  Devices: {len(devices)}")
    print(f"  Interval: {interval}s")
    print(f"  Error profile: {error_profile}")
    print(f"  Max batches: {max_batches or 'unlimited'}")
    print(f"  Press Ctrl+C to stop\n")

    batch_num = 0
    total_messages = 0

    try:
        while True:
            batch_num += 1
            batch_start = time.time()

            print(f"Batch {batch_num} ({datetime.now(timezone.utc).strftime('%H:%M:%S')})")

            for device in devices:
                reading = generate_reading(device, error_profile)

                # Key = device_id → ensures all readings from same device
                # go to the same partition (ordering guaranteed per device)
                key = reading["device_id"]
                value = json.dumps(reading, default=str)

                producer.produce(
                    topic=topic,
                    key=key,
                    value=value,
                    callback=delivery_callback,
                )

                total_messages += 1

                # Handle duplicates for error profiles
                if random.random() < ERROR_PROFILES[error_profile]["dupe_rate"]:
                    producer.produce(
                        topic=topic,
                        key=key,
                        value=value,  # Same message = duplicate
                        callback=delivery_callback,
                    )
                    total_messages += 1

            # Flush: ensure all messages are sent before sleeping
            producer.flush(timeout=10)

            elapsed = time.time() - batch_start
            print(f"  Batch sent in {elapsed:.2f}s | Total messages: {total_messages}\n")

            if max_batches and batch_num >= max_batches:
                print(f"Reached max batches ({max_batches}). Stopping.")
                break

            # Sleep until next batch
            sleep_time = max(0, interval - elapsed)
            time.sleep(sleep_time)

    except KeyboardInterrupt:
        print(f"\nStopping producer. Total: {total_messages} messages in {batch_num} batches.")
    finally:
        # Flush any remaining messages
        remaining = producer.flush(timeout=10)
        if remaining > 0:
            print(f"WARNING: {remaining} messages were not delivered")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="IoT Kafka Producer")
    parser.add_argument("--bootstrap-servers", default="localhost:9093", help="Kafka broker address")
    parser.add_argument("--topic", default="iot.sensor.readings", help="Kafka topic")
    parser.add_argument("--interval", type=float, default=5.0, help="Seconds between batches")
    parser.add_argument("--fast", action="store_true", help="Fast mode (0.5s interval)")
    parser.add_argument("--error-profile", choices=["none", "normal", "high", "chaos"], default="none")
    parser.add_argument("--device", help="Only produce for this device_id")
    parser.add_argument("--max-batches", type=int, help="Stop after N batches")

    args = parser.parse_args()

    run_producer(
        bootstrap_servers=args.bootstrap_servers,
        topic=args.topic,
        interval=0.5 if args.fast else args.interval,
        error_profile=args.error_profile,
        device_filter=args.device,
        max_batches=args.max_batches,
    )
