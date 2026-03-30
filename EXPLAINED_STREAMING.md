# Streaming & Kafka — Complete Guide

## Batch vs Streaming: The Fundamental Difference

```
BATCH (what we had):
  Hour 1: Lambda generates 50 readings → writes 1 JSON file to S3
  Hour 2: Airflow wakes up → COPY INTO loads the file → dbt transforms
  Latency: 60-120 minutes between event and queryable data

STREAMING (what we're adding):
  Second 1: Producer generates 1 reading → sends to Kafka
  Second 2: Consumer reads from Kafka → inserts into Snowflake
  Latency: 1-10 seconds between event and queryable data
```

The data is the same. The question is: **how fast do you need it?**

---

## When to Use Batch vs Streaming

| Scenario | Batch | Streaming | Why |
|----------|-------|-----------|-----|
| Daily KPI dashboard | ✅ | | Refreshed once a day, latency doesn't matter |
| Hourly fleet overview | ✅ | | Our current pipeline — hourly is fine |
| Real-time anomaly alerts | | ✅ | Need to alert in seconds, not hours |
| Fraud detection | | ✅ | Block the transaction before it completes |
| User-facing activity feed | | ✅ | Users expect instant updates |
| Monthly financial reports | ✅ | | Accuracy matters more than speed |
| IoT device monitoring | ✅/✅ | Both work. Batch for history, streaming for live view |
| ML model training | ✅ | | Train on large historical batches |
| ML model serving | | ✅ | Score events in real-time |

**Rule of thumb**: If the consumer can wait an hour, use batch. If they need it in seconds, use streaming. Most companies need both.

---

## Apache Kafka — Core Concepts

### What Is Kafka?

A **distributed event streaming platform**. Think of it as a persistent, ordered, distributed log that multiple producers can write to and multiple consumers can read from.

```
┌──────────┐     ┌───────────────────────────────────┐     ┌──────────┐
│ Producer  │────→│         Kafka Broker               │────→│ Consumer │
│ (Lambda)  │     │                                    │     │ (Python) │
│ (Sensor)  │     │  Topic: iot.sensor.readings        │     │ (Spark)  │
│ (App)     │     │  ┌─────┐ ┌─────┐ ┌─────┐         │     │ (Flink)  │
│           │     │  │ P0  │ │ P1  │ │ P2  │         │     │          │
│           │     │  │msg 0│ │msg 0│ │msg 0│         │     │          │
│           │     │  │msg 1│ │msg 1│ │msg 1│         │     │          │
│           │     │  │msg 2│ │msg 2│ │msg 2│         │     │          │
│           │     │  │ ... │ │ ... │ │ ... │         │     │          │
│           │     │  └─────┘ └─────┘ └─────┘         │     │          │
└──────────┘     └───────────────────────────────────┘     └──────────┘
```

### Topics

A **topic** is a category/feed of messages. Like a database table, but append-only.

```
Our topics:
  iot.sensor.readings   — Main sensor data (temperature, humidity, etc.)
  iot.sensor.alerts      — Anomaly alerts (critical/warning events)
  iot.sensor.deadletter  — Messages that failed processing (for retry/debug)
```

Naming convention: `<domain>.<entity>.<event>` (e.g., `payments.orders.created`)

### Partitions

Each topic is split into **partitions** — ordered, immutable sequences of messages.

```
Topic: iot.sensor.readings (5 partitions)

Partition 0: [msg0] [msg1] [msg2] [msg3] [msg4] → offset 4
Partition 1: [msg0] [msg1] [msg2] →                offset 2
Partition 2: [msg0] [msg1] [msg2] [msg3] →          offset 3
Partition 3: [msg0] [msg1] →                        offset 1
Partition 4: [msg0] [msg1] [msg2] →                 offset 2
```

**Why partitions?**
1. **Parallelism**: 5 partitions = up to 5 consumers reading simultaneously
2. **Ordering**: Messages within a partition are strictly ordered
3. **Scalability**: More partitions = more throughput

**Key-based routing**: Our producer uses `device_id` as the message key. Kafka hashes the key to determine the partition. All messages from `DEV_001` go to the same partition → ordering per device is guaranteed.

```python
producer.produce(topic="iot.sensor.readings", key="DEV_001", value=json.dumps(reading))
# DEV_001 always goes to partition = hash("DEV_001") % 5 = partition 2 (for example)
```

### Offsets

An **offset** is a sequential ID for each message within a partition. It's how consumers track their position.

```
Partition 0: [offset 0] [offset 1] [offset 2] [offset 3] [offset 4]
                                                    ↑
                                          Consumer has read up to here
                                          Committed offset = 3
                                          Next poll returns offset 4
```

**Committed offset**: The consumer tells Kafka "I've processed up to offset 3." If the consumer crashes and restarts, it resumes from offset 4.

**auto.offset.reset**:
- `earliest`: Start from the beginning (offset 0) if no committed offset exists
- `latest`: Start from the newest message (skip history)

### Consumer Groups

Multiple consumers with the same `group.id` **share the work**. Kafka assigns partitions to consumers:

```
Consumer Group: "iot-snowflake-consumer"

5 partitions, 2 consumers:
  Consumer A: Partition 0, 1, 2  (handles 3 partitions)
  Consumer B: Partition 3, 4     (handles 2 partitions)

5 partitions, 5 consumers:
  Consumer A: Partition 0  (1 each — perfect parallelism)
  Consumer B: Partition 1
  Consumer C: Partition 2
  Consumer D: Partition 3
  Consumer E: Partition 4

5 partitions, 7 consumers:
  Consumer A-E: 1 partition each
  Consumer F-G: IDLE (more consumers than partitions = wasted)
```

**Rule**: Max useful consumers = number of partitions.

**Multiple consumer groups** can read the same topic independently:
```
Topic: iot.sensor.readings

Group "snowflake-writer":  Reads all messages → writes to Snowflake
Group "alert-processor":   Reads all messages → checks for anomalies → sends alerts
Group "ml-inference":      Reads all messages → runs ML model → writes predictions

Each group gets ALL messages. They don't interfere with each other.
```

### Producers

**Key concepts in our producer:**

```python
conf = {
    "bootstrap.servers": "localhost:9093",  # Initial Kafka broker to connect to

    # Batching: collect messages for up to 100ms before sending
    "linger.ms": 100,
    # If linger.ms = 0: send immediately (lowest latency, highest network overhead)
    # If linger.ms = 100: buffer for 100ms (higher latency, better throughput)

    # Reliability: how many brokers must confirm the write
    "acks": "all",
    # acks=0: Fire and forget (fastest, messages can be lost)
    # acks=1: Leader confirms (good balance)
    # acks=all: All replicas confirm (safest, slowest)

    # Compression: reduce message size on the wire
    "compression.type": "snappy",  # snappy, gzip, lz4, zstd
}
```

**Delivery callbacks**: Know if your message was actually delivered:
```python
def delivery_callback(err, msg):
    if err:
        print(f"FAILED: {err}")  # Handle: retry, dead letter queue, alert
    else:
        print(f"Delivered to partition {msg.partition()} at offset {msg.offset()}")
```

### Delivery Guarantees

| Guarantee | How | Tradeoff |
|-----------|-----|----------|
| **At-most-once** | Commit offset before processing | Messages can be lost (never duplicated) |
| **At-least-once** | Commit offset after processing | Messages can be duplicated (never lost) |
| **Exactly-once** | Kafka transactions + idempotent producer | Highest overhead, no loss or duplication |

Our consumer uses **at-least-once**: process the message, THEN commit the offset. If we crash between processing and committing, the message will be re-delivered on restart → possible duplicate. Our Snowflake pipeline handles duplicates via `int_readings_deduped`, so this is fine.

---

## Our Kafka Implementation

### Architecture

```
                    ┌─────────────────────┐
                    │    Kafka Broker      │
                    │  ┌────────────────┐  │
 Producer ─────────→│  │ iot.sensor.    │  │─────────→ Consumer (console)
 (producer.py)      │  │   readings     │  │
                    │  │  5 partitions  │  │─────────→ Consumer (snowflake)
                    │  └────────────────┘  │
                    │  ┌────────────────┐  │
                    │  │ iot.sensor.    │  │
                    │  │   alerts       │  │
                    │  └────────────────┘  │
                    │  ┌────────────────┐  │
                    │  │ iot.sensor.    │  │
                    │  │  deadletter    │  │
                    │  └────────────────┘  │
                    └─────────────────────┘
                              │
                         Kafka UI (:8090)
```

### Topics

| Topic | Partitions | Purpose |
|-------|-----------|---------|
| `iot.sensor.readings` | 5 | Main sensor data stream |
| `iot.sensor.alerts` | 3 | Anomaly alerts (future) |
| `iot.sensor.deadletter` | 1 | Failed messages for retry |

5 partitions for readings because we have 5 clusters — could route each cluster to its own partition for locality.

### Data Flow

```
1. Producer generates reading for DEV_001 (FACTORY_A)
2. Serializes to JSON, key = "DEV_001"
3. Kafka hashes "DEV_001" → Partition 2
4. Message appended to Partition 2 at offset 1847
5. Consumer polls Partition 2, gets the message
6. Consumer buffers it (micro-batch of 100 messages)
7. After 100 messages (or 10 seconds), flush to Snowflake
8. INSERT INTO sensor_readings_streaming (raw_data, kafka metadata)
9. Consumer commits offset 1847 → "I've processed this"
```

### Comparing the Two Paths

```sql
-- Batch path (existing):
RAW.sensor_readings         -- Loaded via COPY INTO from S3 (hourly)
  → STAGING.stg_sensor_readings
  → INTERMEDIATE.int_readings_deduped
  → MARTS.fct_hourly_readings

-- Streaming path (new):
RAW.sensor_readings_streaming  -- Loaded via Kafka consumer (seconds)
  → (same dbt models could process this too)
  → (or query directly for real-time dashboards)
```

---

## Running the Stack

### 1. Start Kafka
```bash
cd kafka/
docker compose up -d
# Wait ~30 seconds for Kafka to be healthy
docker compose ps  # All should show "healthy"
```

### 2. Check Kafka UI
Open `http://localhost:8090` (or `http://<EC2-IP>:8090`)
- See topics, partitions, messages
- Monitor consumer groups and lag

### 3. Start Producer (Terminal 1)
```bash
pip install -r requirements.txt

# Test with 3 batches
python producer.py --max-batches 3

# Run continuously
python producer.py --error-profile normal

# Fast mode (0.5s interval)
python producer.py --fast --error-profile normal
```

### 4. Start Consumer (Terminal 2)
```bash
# Console mode (just watch messages)
python consumer.py --mode console

# Read from beginning (see all historical messages)
python consumer.py --mode console --from-beginning

# Write to Snowflake
python consumer.py --mode snowflake --batch-size 50 --flush-interval 5
```

### 5. Compare in Snowflake
```sql
-- See both pipelines side by side
SELECT 'batch' AS pipeline, COUNT(*) FROM RAW.sensor_readings
UNION ALL
SELECT 'streaming', COUNT(*) FROM RAW.sensor_readings_streaming;

-- Latency comparison
-- Run kafka/compare_batch_vs_streaming.sql
```

---

## Kafka vs Alternatives

| | Kafka | AWS Kinesis | Google Pub/Sub | Redpanda | RabbitMQ |
|---|---|---|---|---|---|
| **Type** | Event log | Event log | Message queue | Event log | Message queue |
| **Managed** | No (or Confluent Cloud) | Yes (AWS) | Yes (GCP) | No | No |
| **Ordering** | Per partition | Per shard | No (without key) | Per partition | Per queue |
| **Retention** | Days-forever | 1-365 days | 7 days | Days-forever | Until consumed |
| **Replay** | Yes (seek to offset) | Yes (seek to timestamp) | Yes (seek to snapshot) | Yes | No |
| **Throughput** | Very high | High | High | Very high | Medium |
| **Latency** | ~5ms | ~200ms | ~100ms | ~2ms | ~1ms |
| **Best for** | General streaming | AWS shops | GCP shops | Kafka replacement | Task queues |
| **Ecosystem** | Kafka Connect, ksqlDB, Flink | Lambda integration | Dataflow | Kafka-compatible | Celery, microservices |

### Event Log vs Message Queue

**Event Log** (Kafka, Kinesis): Messages are **retained** after reading. Multiple consumers can read the same messages. Consumers control their position (offset). Think: a newspaper — everyone reads it, the paper stays.

**Message Queue** (RabbitMQ, SQS): Messages are **deleted** after reading. One consumer gets each message. Think: a mailbox — once you take the letter, it's gone.

```
Kafka (Event Log):
  Producer → [msg1] [msg2] [msg3] [msg4] [msg5]
  Consumer A reads msg1-5 ✓ (messages still there)
  Consumer B reads msg1-5 ✓ (same messages, independent)
  msg1-5 expire after retention period (e.g., 24 hours)

RabbitMQ (Message Queue):
  Producer → [msg1] [msg2] [msg3] [msg4] [msg5]
  Consumer A gets msg1, msg3, msg5 (messages removed from queue)
  Consumer B gets msg2, msg4       (different messages)
```

---

## Advanced Kafka Concepts (Interview Questions)

### 1. Exactly-Once Semantics (EOS)
```python
# Idempotent producer: Kafka deduplicates based on producer ID + sequence number
conf = {"enable.idempotence": True}

# Transactional producer: atomic writes across multiple topics/partitions
producer.init_transactions()
producer.begin_transaction()
producer.produce("topic-a", value="msg1")
producer.produce("topic-b", value="msg2")
producer.commit_transaction()  # Both or neither — atomic
```

### 2. Kafka Streams vs Flink vs Spark Streaming

| | Kafka Streams | Apache Flink | Spark Structured Streaming |
|---|---|---|---|
| **What** | Library (Java/Kotlin) | Framework (cluster) | Framework (cluster) |
| **Deploy** | Just a Java app | Flink cluster | Spark cluster |
| **State** | Local RocksDB | Managed state | Managed state |
| **Latency** | ~1ms | ~10ms | ~100ms (micro-batch) |
| **SQL** | ksqlDB | Flink SQL | Spark SQL |
| **Best for** | Simple transforms, microservices | Complex event processing | Batch + streaming unified |

### 3. Schema Registry
When producers and consumers need to agree on message format:

```
Without Schema Registry:
  Producer sends: {"temp": 23.5, "device_id": "DEV_001"}
  Next week, producer changes to: {"temperature": 23.5, "id": "DEV_001"}
  Consumer breaks! Field names changed.

With Schema Registry:
  Producer registers schema: {temp: float, device_id: string}
  Consumer fetches schema from registry
  If producer tries to change field names → Schema Registry REJECTS the change
  (unless it's a backward-compatible change like adding a new optional field)
```

### 4. Log Compaction
For topics that represent **current state** (not events):

```
Normal retention (events):
  [DEV_001: temp=23] [DEV_002: temp=25] [DEV_001: temp=24] [DEV_001: temp=22]
  After retention: all messages deleted

Log compaction (state):
  [DEV_001: temp=23] [DEV_002: temp=25] [DEV_001: temp=24] [DEV_001: temp=22]
  After compaction: keeps LATEST per key
  [DEV_002: temp=25] [DEV_001: temp=22]
```

Use case: "What's the latest firmware version for each device?" — compact topic keeps only the latest value per device_id.

### 5. Consumer Lag
The difference between the latest offset produced and the latest offset consumed:

```
Partition 0: Latest offset = 1000
Consumer committed offset = 950
Lag = 50 messages

If lag keeps growing → consumer can't keep up → need more consumers or faster processing
```

Monitor lag in Kafka UI (localhost:8090) or with `kafka-consumer-groups --describe`.

---

## Streaming in Our Pipeline — The Big Picture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        IoT Fleet Monitor Pipeline                        │
│                                                                          │
│  BATCH PATH (existing):                                                  │
│  EventBridge → Lambda → S3 → Airflow (COPY INTO) → dbt → Marts          │
│  Latency: ~60 min  |  Good for: dashboards, reports, historical analysis │
│                                                                          │
│  STREAMING PATH (new):                                                   │
│  Producer → Kafka → Consumer → Snowflake (direct insert)                 │
│  Latency: ~5 sec   |  Good for: real-time alerts, live monitoring        │
│                                                                          │
│  BOTH paths write to Snowflake → same dbt models can process both        │
│  This is the Lambda Architecture (batch + streaming layers)              │
└─────────────────────────────────────────────────────────────────────────┘
```

### Lambda Architecture vs Kappa Architecture

**Lambda Architecture** (what we're building):
- Batch layer (S3 → Snowflake) for accuracy and completeness
- Speed layer (Kafka → Snowflake) for low-latency access
- Serving layer (dbt marts) merges both
- **Downside**: maintaining two separate pipelines

**Kappa Architecture** (streaming only):
- Everything goes through Kafka
- No batch layer — replay Kafka topic to reprocess
- Simpler (one pipeline) but harder to debug
- **Downside**: reprocessing historical data is expensive

Most companies use **Lambda** — batch for the source of truth, streaming for the live layer.
