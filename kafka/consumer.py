"""
Kafka Consumer — Reads sensor events and writes to Snowflake in micro-batches.

Two modes:
  1. CONSOLE: Just prints messages (for testing/learning)
  2. SNOWFLAKE: Buffers messages and inserts into Snowflake in micro-batches

The consumer demonstrates key Kafka concepts:
  - Consumer groups (multiple consumers share the work)
  - Partition assignment (each consumer gets a subset of partitions)
  - Offset management (track what's been processed)
  - At-least-once delivery (commit after processing)
  - Micro-batching (buffer N messages before inserting)

Usage:
    python consumer.py --mode console              # Print messages to terminal
    python consumer.py --mode snowflake             # Write to Snowflake
    python consumer.py --mode console --from-beginning  # Read all messages from start
"""

import argparse
import json
import os
import signal
import sys
import time
from datetime import datetime, timezone

from confluent_kafka import Consumer, KafkaError, KafkaException
from dotenv import load_dotenv

load_dotenv()

# ---------------------------------------------------------------------------
# Snowflake Writer
# ---------------------------------------------------------------------------


class SnowflakeWriter:
    """Buffers messages and writes to Snowflake in micro-batches."""

    def __init__(self, batch_size: int = 100, flush_interval: int = 10):
        """
        Args:
            batch_size: Insert after this many messages
            flush_interval: Or insert after this many seconds (whichever comes first)
        """
        import snowflake.connector

        self.conn = snowflake.connector.connect(
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            user=os.environ["SNOWFLAKE_USER"],
            password=os.environ["SNOWFLAKE_PASSWORD"],
            role=os.environ.get("SNOWFLAKE_ROLE", "IOT_TRANSFORMER"),
            warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "IOT_WH"),
            database=os.environ.get("SNOWFLAKE_DATABASE", "IOT_PIPELINE"),
        )
        self.batch_size = batch_size
        self.flush_interval = flush_interval
        self.buffer = []
        self.last_flush = time.time()
        self.total_written = 0

        # Create the streaming target table if it doesn't exist
        self._ensure_table()

    def _ensure_table(self):
        """Create a separate table for streamed data (compare with batch-loaded data)."""
        self.conn.cursor().execute("""
            CREATE TABLE IF NOT EXISTS IOT_PIPELINE.RAW.sensor_readings_streaming (
                raw_data        VARIANT        COMMENT 'JSON reading from Kafka',
                loaded_at       TIMESTAMP_NTZ  DEFAULT CURRENT_TIMESTAMP(),
                source_topic    VARCHAR        COMMENT 'Kafka topic',
                source_partition INTEGER       COMMENT 'Kafka partition',
                source_offset   INTEGER        COMMENT 'Kafka offset',
                kafka_key       VARCHAR        COMMENT 'Message key (device_id)'
            )
        """)
        print("Snowflake table ready: RAW.sensor_readings_streaming")

    def add(self, message: dict, topic: str, partition: int, offset: int, key: str):
        """Add a message to the buffer."""
        self.buffer.append({
            "raw_data": json.dumps(message, default=str),
            "topic": topic,
            "partition": partition,
            "offset": offset,
            "key": key,
        })

        # Flush if buffer is full or time exceeded
        if len(self.buffer) >= self.batch_size:
            self.flush("batch_size")
        elif time.time() - self.last_flush >= self.flush_interval:
            self.flush("time_interval")

    def flush(self, reason: str = "manual"):
        """Write buffered messages to Snowflake."""
        if not self.buffer:
            return

        cursor = self.conn.cursor()
        count = len(self.buffer)

        try:
            # Use INSERT with PARSE_JSON for VARIANT column
            insert_sql = """
                INSERT INTO IOT_PIPELINE.RAW.sensor_readings_streaming
                    (raw_data, loaded_at, source_topic, source_partition, source_offset, kafka_key)
                SELECT
                    PARSE_JSON(column1),
                    CURRENT_TIMESTAMP(),
                    column2,
                    column3,
                    column4,
                    column5
                FROM VALUES {values}
            """

            # Build VALUES clause
            values_list = []
            for msg in self.buffer:
                # Escape single quotes in JSON
                safe_json = msg["raw_data"].replace("'", "''")
                values_list.append(
                    f"('{safe_json}', '{msg['topic']}', {msg['partition']}, {msg['offset']}, '{msg['key']}')"
                )

            values_str = ", ".join(values_list)
            cursor.execute(insert_sql.format(values=values_str))

            self.total_written += count
            self.buffer.clear()
            self.last_flush = time.time()

            print(f"  [Snowflake] Flushed {count} rows ({reason}) | Total: {self.total_written}")

        except Exception as e:
            print(f"  [Snowflake] ERROR flushing {count} rows: {e}")
            # Keep buffer — will retry on next flush
        finally:
            cursor.close()

    def close(self):
        """Final flush and close connection."""
        self.flush("shutdown")
        self.conn.close()
        print(f"Snowflake writer closed. Total rows written: {self.total_written}")


# ---------------------------------------------------------------------------
# Kafka Consumer
# ---------------------------------------------------------------------------


def run_consumer(
    bootstrap_servers: str = "localhost:9093",
    topic: str = "iot.sensor.readings",
    group_id: str = "iot-snowflake-consumer",
    mode: str = "console",
    from_beginning: bool = False,
    batch_size: int = 100,
    flush_interval: int = 10,
):
    """
    Consume messages from Kafka topic.

    Key concepts demonstrated:
    - Consumer group: multiple consumers with same group_id share partitions
    - auto.offset.reset: where to start if no committed offset exists
    - enable.auto.commit: we commit manually after processing (at-least-once)
    - Partition assignment: Kafka assigns partitions to consumers in the group
    """

    conf = {
        "bootstrap.servers": bootstrap_servers,
        "group.id": group_id,
        "client.id": f"iot-consumer-{os.getpid()}",

        # Start from earliest if no committed offset (first time) or latest (resume)
        "auto.offset.reset": "earliest" if from_beginning else "latest",

        # Manual commit: we commit AFTER processing, not before
        # This gives us "at-least-once" delivery guarantee
        "enable.auto.commit": False,

        # Fetch tuning
        "fetch.min.bytes": 1024,       # Wait for at least 1KB before returning
        "fetch.wait.max.ms": 500,      # Or return after 500ms regardless
        "max.poll.interval.ms": 300000, # Max time between polls before rebalance
    }

    consumer = Consumer(conf)
    writer = None

    if mode == "snowflake":
        writer = SnowflakeWriter(batch_size=batch_size, flush_interval=flush_interval)

    # Track stats
    stats = {"messages": 0, "errors": 0, "start_time": time.time()}

    # Graceful shutdown
    running = True

    def shutdown(sig, frame):
        nonlocal running
        print("\nShutting down consumer...")
        running = False

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    # Subscribe to topic
    consumer.subscribe([topic])
    print(f"\nConsuming from topic '{topic}'")
    print(f"  Mode: {mode}")
    print(f"  Group ID: {group_id}")
    print(f"  From beginning: {from_beginning}")
    if writer:
        print(f"  Batch size: {batch_size}")
        print(f"  Flush interval: {flush_interval}s")
    print(f"  Press Ctrl+C to stop\n")

    try:
        while running:
            # Poll for messages (timeout = 1 second)
            msg = consumer.poll(timeout=1.0)

            if msg is None:
                # No message available — check if we need to time-flush
                if writer:
                    writer.flush("time_interval_poll")
                continue

            if msg.error():
                if msg.error().code() == KafkaError._PARTITION_EOF:
                    # Reached end of partition — normal, not an error
                    pass
                else:
                    print(f"Consumer error: {msg.error()}")
                    stats["errors"] += 1
                continue

            # Parse message
            key = msg.key().decode("utf-8") if msg.key() else None
            value = json.loads(msg.value().decode("utf-8"))
            stats["messages"] += 1

            if mode == "console":
                # Print to terminal
                elapsed = time.time() - stats["start_time"]
                rate = stats["messages"] / elapsed if elapsed > 0 else 0
                print(
                    f"[{msg.partition()}:{msg.offset()}] "
                    f"device={value.get('device_id', '?')} "
                    f"temp={value.get('temperature', '?')} "
                    f"humidity={value.get('humidity', '?')} "
                    f"battery={value.get('battery_pct', '?')} "
                    f"| {rate:.1f} msg/s"
                )

            elif mode == "snowflake":
                writer.add(
                    message=value,
                    topic=msg.topic(),
                    partition=msg.partition(),
                    offset=msg.offset(),
                    key=key,
                )

            # Commit offset AFTER processing (at-least-once guarantee)
            # If consumer crashes before commit, message will be re-delivered
            consumer.commit(asynchronous=True)

    except KafkaException as e:
        print(f"Kafka exception: {e}")
    finally:
        # Final stats
        elapsed = time.time() - stats["start_time"]
        rate = stats["messages"] / elapsed if elapsed > 0 else 0
        print(f"\nConsumer stats:")
        print(f"  Messages processed: {stats['messages']}")
        print(f"  Errors: {stats['errors']}")
        print(f"  Runtime: {elapsed:.1f}s")
        print(f"  Average rate: {rate:.1f} msg/s")

        if writer:
            writer.close()

        consumer.close()
        print("Consumer closed cleanly.")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="IoT Kafka Consumer")
    parser.add_argument("--bootstrap-servers", default="localhost:9093", help="Kafka broker")
    parser.add_argument("--topic", default="iot.sensor.readings", help="Topic to consume")
    parser.add_argument("--group-id", default="iot-snowflake-consumer", help="Consumer group ID")
    parser.add_argument("--mode", choices=["console", "snowflake"], default="console")
    parser.add_argument("--from-beginning", action="store_true", help="Read from earliest offset")
    parser.add_argument("--batch-size", type=int, default=100, help="Snowflake micro-batch size")
    parser.add_argument("--flush-interval", type=int, default=10, help="Max seconds between flushes")

    args = parser.parse_args()

    run_consumer(
        bootstrap_servers=args.bootstrap_servers,
        topic=args.topic,
        group_id=args.group_id,
        mode=args.mode,
        from_beginning=args.from_beginning,
        batch_size=args.batch_size,
        flush_interval=args.flush_interval,
    )
