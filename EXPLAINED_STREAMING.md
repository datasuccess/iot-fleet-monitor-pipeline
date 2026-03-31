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

## What Is Kafka? (The Big Picture)

Imagine a **post office** that never throws away letters.

- **Producers** are people mailing letters (our Python producer sending sensor readings)
- **The post office** is Kafka — it receives, stores, and organizes all mail
- **Consumers** are people picking up mail (our Python consumer reading messages)
- **Mailboxes** are topics — different categories of mail (sensor readings, alerts, etc.)

The key difference from a real post office: **letters are never removed**. A consumer reads a letter, but it stays in the mailbox. Another consumer can read the same letter. Letters only disappear after a **retention period** (we set 24 hours).

This is fundamentally different from a **message queue** (RabbitMQ, SQS) where reading a message deletes it.

```
Traditional message queue (RabbitMQ):
  Message → Queue → Consumer reads it → Message DELETED
  Another consumer? Too late, it's gone.

Kafka (event log):
  Message → Topic → Consumer A reads it → Message STILL THERE
                   → Consumer B reads it → Message STILL THERE
                   → 24 hours pass → Message expires
```

---

## Kafka Architecture — Every Component Explained

```
┌──────────────────────────────────────────────────────────────────────┐
│                        KAFKA CLUSTER                                  │
│                                                                       │
│  ┌─────────────┐    ┌─────────────────────────────────────────────┐  │
│  │  Zookeeper   │    │              Broker (kafka:29092)            │  │
│  │              │    │                                              │  │
│  │ - Tracks     │    │  Topic: iot.sensor.readings                  │  │
│  │   which      │◄──►│  ┌────────┐ ┌────────┐ ┌────────┐          │  │
│  │   brokers    │    │  │ Part 0 │ │ Part 1 │ │ Part 2 │ ...      │  │
│  │   are alive  │    │  │ off:0  │ │ off:0  │ │ off:0  │          │  │
│  │ - Stores     │    │  │ off:1  │ │ off:1  │ │ off:1  │          │  │
│  │   topic      │    │  │ off:2  │ │ off:2  │ │ off:2  │          │  │
│  │   metadata   │    │  │  ...   │ │  ...   │ │  ...   │          │  │
│  │ - Manages    │    │  └────────┘ └────────┘ └────────┘          │  │
│  │   leader     │    │                                              │  │
│  │   election   │    │  Topic: iot.sensor.alerts                    │  │
│  │              │    │  ┌────────┐ ┌────────┐ ┌────────┐          │  │
│  │              │    │  │ Part 0 │ │ Part 1 │ │ Part 2 │          │  │
│  │              │    │  └────────┘ └────────┘ └────────┘          │  │
│  └─────────────┘    └─────────────────────────────────────────────┘  │
│                                                                       │
└────────────────────────────┬──────────────────────────────────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
        ┌─────┴─────┐ ┌─────┴─────┐ ┌─────┴─────┐
        │ Producer   │ │ Consumer  │ │ Kafka UI  │
        │ (writes)   │ │ (reads)   │ │ (monitor) │
        │ port 9092  │ │ port 9092 │ │ port 8090 │
        └───────────┘ └───────────┘ └───────────┘
```

### 1. Zookeeper — The Coordinator

**What you see in Kafka UI**: Nothing directly — Zookeeper works behind the scenes.

**What it does**: Think of it as Kafka's brain/secretary. It:
- Knows which brokers are alive
- Stores topic configuration (how many partitions, retention period)
- Manages leader election (which broker is responsible for which partition)
- Tracks consumer group membership

**Why it exists**: Kafka is designed to run as a cluster (multiple brokers). Someone needs to coordinate them. That's Zookeeper.

**The future**: Kafka is replacing Zookeeper with **KRaft** (Kafka Raft). Newer versions don't need Zookeeper at all. We use Zookeeper because it's still the default in most deployments.

```
Our docker-compose:
  zookeeper:2181  ← Kafka connects here for coordination
  kafka:29092     ← Internal communication (Docker network)
  kafka:9092      ← External communication (your producer/consumer)
```

---

### 2. Broker — The Server That Stores Messages

**What you see in Kafka UI**: Click **"Brokers"** tab → shows our single broker with ID 1.

**What it does**: A broker is a single Kafka server. It:
- Receives messages from producers
- Stores them on disk (not just in memory — Kafka is **durable**)
- Serves messages to consumers
- Manages partitions assigned to it

**In production**: You'd have 3-5+ brokers for redundancy. If one dies, others take over. We have 1 broker because it's a learning project.

```
Production cluster:
  Broker 1: Partition 0 (leader), Partition 3 (follower)
  Broker 2: Partition 1 (leader), Partition 0 (follower)
  Broker 3: Partition 2 (leader), Partition 1 (follower)

  If Broker 1 dies → Broker 2 becomes leader for Partition 0
  No data loss, no downtime.

Our setup:
  Broker 1: All partitions (leader, no followers — single point of failure)
```

**Key broker metrics** (visible in Kafka UI → Brokers):
- **Bytes in/out per sec**: How much data flowing through
- **Active controllers**: Should be 1 (the broker managing cluster metadata)
- **Under-replicated partitions**: Should be 0 (means all copies are in sync)

---

### 3. Topic — A Category of Messages

**What you see in Kafka UI**: Click **"Topics"** tab → shows our 3 topics.

**What it is**: A topic is a named stream of messages. Like a database table, but append-only (you can only add messages, never update or delete them).

```
Our topics:
┌────────────────────────┬────────────┬─────────────────────────────────────┐
│ Topic                   │ Partitions │ Purpose                              │
├────────────────────────┼────────────┼─────────────────────────────────────┤
│ iot.sensor.readings     │ 5          │ Main sensor data stream              │
│ iot.sensor.alerts       │ 3          │ Anomaly alerts (critical/warning)    │
│ iot.sensor.deadletter   │ 1          │ Messages that failed processing      │
└────────────────────────┴────────────┴─────────────────────────────────────┘
```

**Naming convention**: `<domain>.<entity>.<event>`. Examples:
- `payments.orders.created`
- `users.profiles.updated`
- `iot.sensor.readings`

**Topic settings** (visible in Kafka UI → click a topic → Settings):
- **retention.ms**: How long to keep messages (86400000 = 24 hours)
- **retention.bytes**: Max storage per partition (1 GB)
- **cleanup.policy**: `delete` (remove old messages) or `compact` (keep latest per key)
- **min.insync.replicas**: How many brokers must confirm a write (1 for us)

**What you see when you click a topic**:
- **Overview**: partition count, replication factor, message count
- **Messages**: actual message content — click "Produce Message" to manually send one
- **Consumers**: which consumer groups are reading this topic
- **Settings**: all topic configuration

---

### 4. Partition — How Topics Scale

**What you see in Kafka UI**: Click a topic → **"Partitions"** tab → shows 5 partitions with their offsets.

**What it is**: A topic is split into partitions. Each partition is an **ordered, immutable sequence of messages**.

```
Topic: iot.sensor.readings

Partition 0: [msg0] [msg1] [msg2] [msg3] [msg4] [msg5]  ← offset 5
Partition 1: [msg0] [msg1] [msg2] [msg3]                 ← offset 3
Partition 2: [msg0] [msg1] [msg2] [msg3] [msg4]          ← offset 4
Partition 3: [msg0] [msg1] [msg2]                         ← offset 2
Partition 4: [msg0] [msg1] [msg2] [msg3]                 ← offset 3

Each partition may have different numbers of messages because
messages are distributed based on the key hash.
```

**Why partitions exist**:

1. **Parallelism**: 5 partitions = up to 5 consumers can read simultaneously. 1 partition = only 1 consumer. More partitions = more throughput.

2. **Ordering guarantee**: Messages within a partition are **strictly ordered**. Across partitions, there's **no ordering guarantee**.

3. **Key-based routing**: Our producer uses `device_id` as the message key:
   ```python
   producer.produce(topic="iot.sensor.readings", key="DEV_001", value=json.dumps(reading))
   ```
   Kafka hashes the key: `hash("DEV_001") % 5 = partition 2` (for example). All messages from DEV_001 **always** go to partition 2. This guarantees ordering per device.

**Why this matters for IoT**:
```
Without keys (random partition):
  DEV_001 reading at 10:00 → Partition 3
  DEV_001 reading at 10:05 → Partition 1
  DEV_001 reading at 10:10 → Partition 3
  Consumer reads Partition 1: sees 10:05 before 10:00 — OUT OF ORDER!

With key=device_id:
  DEV_001 reading at 10:00 → Partition 2 (always)
  DEV_001 reading at 10:05 → Partition 2 (always)
  DEV_001 reading at 10:10 → Partition 2 (always)
  Consumer reads Partition 2: sees 10:00, 10:05, 10:10 — CORRECT ORDER!
```

**How many partitions should you have?**
- Rule of thumb: partitions = expected peak throughput (MB/s) / consumer throughput per partition
- More partitions = more parallelism but more overhead
- Start with 5-10, increase if consumers can't keep up
- You can **increase** partitions later but **never decrease** them

---

### 5. Offset — Your Position in the Stream

**What you see in Kafka UI**: Click a topic → Messages tab → each message shows its offset number.

**What it is**: A sequential ID for each message within a partition. Think of it as a page number in a book.

```
Partition 0:
  Offset 0: {"device_id": "DEV_001", "temperature": 23.5, ...}  ← oldest
  Offset 1: {"device_id": "DEV_011", "temperature": 28.1, ...}
  Offset 2: {"device_id": "DEV_021", "temperature": 17.9, ...}
  Offset 3: {"device_id": "DEV_031", "temperature": 33.2, ...}
  Offset 4: {"device_id": "DEV_041", "temperature": 11.8, ...}  ← newest
```

**Consumer tracks its position via offset**:
```
"I've processed up to offset 3 in partition 0"
→ Next poll returns offset 4
→ If I crash and restart, I resume from offset 4 (not from 0)
```

**Committed offset**: The consumer periodically tells Kafka "I've processed up to here." This is called **committing**. If the consumer crashes, it restarts from the last committed offset.

**auto.offset.reset** (what happens on first connection):
- `earliest`: Start from offset 0 (read ALL historical messages)
- `latest`: Start from the newest message (skip history)

```
Our consumer with --from-beginning uses "earliest":
  → Reads every message ever produced (within retention period)

Our consumer without --from-beginning uses "latest":
  → Only sees NEW messages produced after it connects
```

---

### 6. Consumer Group — Sharing the Work

**What you see in Kafka UI**: Click **"Consumer Groups"** tab → shows `iot-snowflake-consumer`.

**What it is**: Multiple consumers with the same `group.id` form a group. Kafka **distributes partitions** among them so they share the work.

```
Example: 5 partitions, Consumer Group "iot-snowflake-consumer"

1 consumer in the group:
  Consumer A: reads Partition 0, 1, 2, 3, 4 (does everything alone)

2 consumers in the group:
  Consumer A: reads Partition 0, 1, 2
  Consumer B: reads Partition 3, 4
  (work is split!)

5 consumers in the group:
  Consumer A: reads Partition 0
  Consumer B: reads Partition 1
  Consumer C: reads Partition 2
  Consumer D: reads Partition 3
  Consumer E: reads Partition 4
  (perfect parallelism — each consumer handles 1 partition)

7 consumers in the group:
  Consumer A-E: 1 partition each
  Consumer F: IDLE (no partition to read — wasted!)
  Consumer G: IDLE
  Rule: max useful consumers = number of partitions
```

**What you see in Kafka UI → Consumer Groups**:
- **Group ID**: `iot-snowflake-consumer`
- **State**: `Stable` (all consumers connected), `Rebalancing` (redistributing partitions), `Empty` (no active consumers)
- **Members**: which consumers are in the group
- **Topic assignments**: which partitions each consumer is reading
- **Lag**: how far behind the consumer is (see below)

**Rebalancing**: When a consumer joins or leaves the group, Kafka redistributes partitions. This takes a few seconds and pauses consumption. You can see this happening in the UI when state changes to `Rebalancing`.

**Multiple consumer groups read independently**:
```
Topic: iot.sensor.readings

Group "snowflake-writer":  Reads ALL messages → writes to database
Group "alert-checker":     Reads ALL messages → checks for anomalies
Group "dashboard-feeder":  Reads ALL messages → feeds real-time dashboard

Each group gets every message. They track their own offsets independently.
They don't interfere with each other.
```

---

### 7. Consumer Lag — The Most Important Metric

**What you see in Kafka UI**: Consumer Groups → click your group → shows lag per partition.

**What it is**: The difference between the **latest produced offset** and the **latest consumed offset**.

```
Partition 0:
  Latest offset (produced):  1000
  Committed offset (consumed): 950
  LAG = 50 messages

What this means:
  - Producer has written 1000 messages
  - Consumer has processed 950
  - 50 messages are waiting to be consumed
```

**How to interpret lag**:
```
Lag = 0          → Consumer is caught up (real-time)
Lag = small      → Consumer is slightly behind (normal, processing takes time)
Lag growing      → Consumer can't keep up! Need more consumers or faster processing
Lag = very large → Consumer was down for a while (like our Airflow recovery scenario)
```

**This is exactly like our pipeline health view!**
```
Batch pipeline:
  "loaded_at is 3 hours old" = Airflow is behind = 3 hours of lag

Kafka:
  "consumer offset is 1000 behind" = consumer is behind = lag of 1000 messages
```

**Try this experiment**:
1. Stop the consumer (Ctrl+C)
2. Let the producer run for a minute
3. Check Kafka UI → Consumer Groups → lag is growing!
4. Restart the consumer with `--from-beginning`
5. Watch the lag drop back to 0 as the consumer catches up

---

### 8. Producer — Writing Messages

**What you see in Kafka UI**: Click a topic → Messages → see the messages your producer wrote.

**What a producer does**:
```
1. Serialize the message (Python dict → JSON string → bytes)
2. Determine the partition (hash the key, mod by partition count)
3. Send to the broker's partition leader
4. Wait for acknowledgment (or not, depending on acks setting)
5. Call the delivery callback (success or failure)
```

**Our producer config explained**:
```python
conf = {
    "bootstrap.servers": "localhost:9092",
    # ↑ Initial broker to connect to. Kafka returns the full broker list.
    #   "Bootstrap" because you only need one to discover the rest.

    "client.id": "iot-sensor-producer",
    # ↑ Identifies this producer in Kafka logs and UI.

    "linger.ms": 100,
    # ↑ Wait up to 100ms to collect messages into a batch before sending.
    #   0 = send immediately (lowest latency, most network calls)
    #   100 = batch for 100ms (slightly higher latency, fewer network calls)
    #   Tradeoff: latency vs throughput

    "batch.size": 65536,
    # ↑ Max batch size in bytes (64 KB). When the batch reaches this size,
    #   send immediately (don't wait for linger.ms).

    "acks": "all",
    # ↑ How many brokers must confirm the write:
    #   "0" = fire and forget (fastest, messages can be LOST)
    #   "1" = leader confirms (good balance)
    #   "all" = all replicas confirm (safest, slowest)
    #   We use "all" but with 1 broker it's the same as "1"

    "compression.type": "snappy",
    # ↑ Compress messages before sending.
    #   "none" = no compression
    #   "snappy" = fast compression, moderate ratio (default choice)
    #   "gzip" = slow compression, best ratio
    #   "zstd" = good balance (newer, recommended for large messages)
    #   "lz4" = fastest compression
}
```

**Message structure** (what you see in Kafka UI → Messages → click a message):
```json
{
  "Key": "DEV_001",           ← Determines partition (hash → partition 2)
  "Value": {                   ← The actual data
    "reading_id": "abc-123",
    "device_id": "DEV_001",
    "temperature": 23.5,
    "humidity": 65.2,
    ...
  },
  "Partition": 2,              ← Which partition it landed in
  "Offset": 847,               ← Sequential position in that partition
  "Timestamp": 1774940571167,  ← When it was produced (epoch ms)
  "Headers": {}                ← Optional metadata (not used by us)
}
```

---

### 9. Message Retention — How Long Messages Live

**What you see in Kafka UI**: Click a topic → Settings → `retention.ms` and `retention.bytes`.

**How it works**:
```
retention.ms = 86400000 (24 hours)
retention.bytes = 1073741824 (1 GB per partition)

Whichever limit is hit FIRST triggers cleanup:
  - Message is 25 hours old → DELETED (exceeded retention.ms)
  - Partition reaches 1.1 GB → oldest messages DELETED (exceeded retention.bytes)
  - Message is 1 hour old and partition is 500 MB → KEPT (neither limit hit)
```

**Retention in different systems**:
```
Kafka:              Configurable (hours to forever). Default 7 days.
AWS Kinesis:        1 to 365 days. Default 24 hours.
Google Pub/Sub:     7 days max.
RabbitMQ:          Until consumed (then deleted).
Our S3 pipeline:   Forever (S3 files don't expire unless you set lifecycle rules).
```

**Log compaction** (alternative to time-based retention):
```
Normal retention (for events — our sensor readings):
  [DEV_001: temp=23] [DEV_002: temp=25] [DEV_001: temp=24] [DEV_001: temp=22]
  After 24h: ALL messages deleted

Log compaction (for state — e.g., "latest config per device"):
  [DEV_001: firmware=v1.0] [DEV_002: firmware=v2.0] [DEV_001: firmware=v1.1]
  After compaction: keeps ONLY the latest value per key
  Result: [DEV_002: firmware=v2.0] [DEV_001: firmware=v1.1]

  Use case: "What's the current firmware for each device?"
  The topic becomes a key-value store!
```

---

### 10. Dead Letter Queue (DLQ) — Handling Failures

**What you see in Kafka UI**: Topic `iot.sensor.deadletter` (probably empty right now).

**What it is**: When a consumer can't process a message (corrupt JSON, schema mismatch, Snowflake down), instead of crashing or losing the message, it forwards it to the dead letter topic.

```
Normal flow:
  iot.sensor.readings → Consumer → Snowflake ✓

Failed message:
  iot.sensor.readings → Consumer → ERROR! → iot.sensor.deadletter

Later:
  iot.sensor.deadletter → Review → Fix → Reprocess
```

**Why this matters**: In production, you NEVER want to lose data and you NEVER want one bad message to stop the whole pipeline. DLQ gives you both.

---

## What to Look for in Kafka UI

### Dashboard (Home Page)
- **Broker count**: 1 (us) or 3+ (production)
- **Topic count**: 3 (readings, alerts, deadletter)
- **Bytes in/out**: Data flowing through the system

### Topics Tab
Click `iot.sensor.readings`:
- **Messages**: See actual JSON payloads from our producer
- **Partitions**: 5 partitions, each with its own offset counter
- **Consumers**: Which consumer groups are reading this topic
- **Settings**: Retention, cleanup policy, replication

### Consumer Groups Tab
Click `iot-snowflake-consumer`:
- **State**: Stable (connected), Empty (no consumers), Dead (timed out)
- **Members**: How many consumers are active
- **Lag per partition**: THE key metric — is the consumer keeping up?
- **Committed offsets vs end offsets**: Visual gap = lag

### Brokers Tab
- **Broker 1**: Our single broker
- **Host**: kafka:29092 (internal Docker address)
- **Partitions**: How many partitions this broker manages
- **Disk usage**: How much storage messages are using

---

## Real-World Experiments to Try

### Experiment 1: Consumer Recovery (like our Airflow recovery)
```bash
# Terminal 1: Producer running
python producer.py --bootstrap-servers localhost:9092 --error-profile normal --interval 10

# Terminal 2: Stop consumer (Ctrl+C)
# Watch Kafka UI → Consumer Groups → lag GROWS

# Wait 1-2 minutes...

# Terminal 2: Restart consumer
python consumer.py --mode console --bootstrap-servers localhost:9092
# Watch it process all missed messages at full speed
# Kafka UI → lag drops back to 0
```

### Experiment 2: Partition Rebalancing
```bash
# Terminal 2: Consumer A running (gets all 5 partitions)
python consumer.py --mode console --bootstrap-servers localhost:9092

# Terminal 3: Start Consumer B with SAME group ID
python consumer.py --mode console --bootstrap-servers localhost:9092

# Watch Kafka UI → Consumer Groups → partitions redistribute!
# Consumer A: partitions 0,1,2
# Consumer B: partitions 3,4
```

### Experiment 3: Chaos Mode
```bash
# Stop producer, restart with chaos
python producer.py --bootstrap-servers localhost:9092 --error-profile chaos --interval 5

# Watch the console consumer — see null temperatures, out-of-range values (999°C)
# In production, the consumer would route these to the dead letter topic
```

### Experiment 4: Different Consumer Groups
```bash
# Terminal 2: Consumer group "team-a"
python consumer.py --mode console --bootstrap-servers localhost:9092 --group-id team-a

# Terminal 3: Consumer group "team-b"
python consumer.py --mode console --bootstrap-servers localhost:9092 --group-id team-b

# Both get ALL messages independently
# Kafka UI shows 2 consumer groups, each with their own offsets
```

### Experiment 5: Replay from Beginning
```bash
# New consumer group, read ALL historical messages
python consumer.py --mode console --bootstrap-servers localhost:9092 --group-id replay-test --from-beginning

# Instantly processes thousands of messages that are still in retention
# This is why Kafka is an "event log" — you can always go back
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
