# Interview Q&A — IoT Fleet Monitor Pipeline

## Round 2: Data Modeling & Architecture (Architect-Level)

### Q6. A startup asks you to design their analytics platform from scratch. They have 3 data sources, 5 analysts, and need dashboards. What modeling approach do you choose and why? What if they grow to 50 sources and 10 domain teams in 2 years?

**Answer:**

**For the startup (3 sources, 5 analysts):** Star schema, no question. It's the default for analytics — simple to understand, fast to query, and every BI tool is optimized for it. With 3 sources, I'd build a small set of fact tables (**one per business process**) and shared dimension tables. The analysts can write SQL against it directly. I'd use dbt for transforms and Snowflake or BigQuery as the warehouse.

I would NOT use Data Vault (overkill for 3 sources, small team can't maintain it), snowflake schema (extra JOINs for no benefit at this scale), or One Big Table (no separation of concerns, update nightmares).

**If they grow to 50 sources and 10 domain teams:** Two things change:
1. **Data Vault as the integration layer.** With 50 sources feeding the same entities (e.g., "customer" from CRM, billing, and support), you need a **source-agnostic integration model**. Data Vault's hub/satellite pattern handles this — each source loads independently, no coordination needed.
2. **Data Mesh principles.** 10 domain teams means the central data team becomes a bottleneck. Each domain owns their own data as a product: their own dbt models, quality tests, SLAs. A central platform team provides shared infrastructure (warehouse, Airflow, dbt templates) — not the data itself.

The architecture becomes: Sources → Data Vault (integration) → Star Schema marts (per domain) → BI tools. Each domain team builds their own mart on top of shared Data Vault hubs.

---

### Q7. Explain the difference between star schema and snowflake schema. Your project uses star schema — under what specific conditions would you refactor to snowflake schema? Give a concrete example using your IoT domain.

**Answer:**

**Star schema:** Fact table surrounded by denormalized dimension tables. Each dimension is a single flat table — `dim_devices` has `device_id`, `device_type`, `cluster_id`, `cluster_city`, `timezone` all in one row. Query: 1 JOIN from fact to dimension.

**Snowflake schema:** Same structure but dimensions are normalized into sub-tables. `dim_device` has a FK to `dim_cluster`, which has a FK to `dim_region`. Query: 2-3 JOINs to get cluster_city.

**Our project uses star because:**
- 50 devices, 5 clusters — the "redundancy" of storing "New York" 10 times in dim_devices costs ~500 bytes. Irrelevant.
- Analysts JOIN `fct_hourly_readings` to `dim_devices` directly. Simple, fast, readable.

**When I'd refactor to snowflake schema — concrete IoT example:**

Suppose the fleet grows to 10,000 devices across 500 clusters in 50 regions, and each cluster has 20 attributes (city, timezone, building_type, floor, safety_zone, maintenance_schedule, manager, SLA_tier...). Now:

- `dim_devices` has 10,000 rows × 20 cluster attributes repeated. "Building 7A, Floor 3, Safety Zone Red, Manager: John Smith" is duplicated across 200 devices in that cluster.
- A cluster manager changes → UPDATE 200 rows in dim_devices vs. UPDATE 1 row in dim_cluster.
- BI tools want to drill down: Region → Cluster → Device. A normalized hierarchy makes this natural.

At that point, normalizing into `dim_device → dim_cluster → dim_region` saves storage, simplifies updates, and maps to the BI hierarchy. But for 50 devices and 5 clusters? Star schema wins on simplicity.

---

### Q8. Your `dim_devices` uses SCD Type 2 with surrogate keys. A junior engineer asks: "Why can't we just UPDATE the row when firmware changes? It's simpler." What do you tell them? When IS Type 1 (overwrite) actually the right call?

**Answer:**

**Why not just UPDATE (Type 1):**

"If you UPDATE `dim_devices` when DEV_001 goes from firmware v1.0 to v2.0, every historical fact row that joined to DEV_001 now shows v2.0 — even readings from 6 months ago when it was running v1.0. You've rewritten history."

Concrete problem: "Show me average temperature by firmware version." With Type 1, all readings show v2.0. With Type 2, readings before June join to the v1.0 row, readings after June join to v2.0. You get accurate historical analysis.

SCD Type 2 keeps both versions:
```
device_key=1 | DEV_001 | v1.0 | valid_from=Jan | valid_to=Jun
device_key=2 | DEV_001 | v2.0 | valid_from=Jun | valid_to=NULL
```

The surrogate key (`device_key`) gives each version a unique identity. Fact tables join on `device_key`, not `device_id`, so they always point to the correct historical version.

**When Type 1 IS correct:**
- **Correcting data entry errors.** Someone misspelled a device name as "Tempreture Sensor" → just UPDATE to "Temperature Sensor." This isn't a change, it's a fix. No history to preserve.
- **Attributes nobody analyzes historically.** If `device_color` changes from "gray" to "blue" and no analyst will ever ask "what color was it last year?", Type 1 is fine. Don't track history nobody needs.
- **Reference data that's definitionally current.** Country codes, currency symbols — these don't have meaningful historical versions.

**Rule of thumb:** "Will an analyst ever ask 'what was this value at a point in time?'" Yes → Type 2. No → Type 1.

---

### Q9. What's the difference between a data lake, data warehouse, and data lakehouse? Don't just define them — explain why lakehouses emerged. What problem did they solve that the other two couldn't on their own? How does your pipeline implement all three?

**Answer:**

**Data Warehouse (Snowflake):** Structured, schema-enforced, SQL-optimized. Fast queries, strong governance, ACID transactions. But expensive for raw/unstructured data, and data is locked in a proprietary format.

**Data Lake (S3):** Cheap, any format, any volume. Store raw JSON, CSV, images, ML training data. But no schema enforcement (data swamp risk), no ACID transactions, inconsistent query performance.

**The problem neither solved alone:**
- Data scientists wanted to train ML models on warehouse data → had to export to files, losing freshness and governance.
- Analysts wanted to query lake data with SQL → either slow (Athena on raw JSON) or required duplicate loading into a warehouse.
- Companies ended up maintaining both — same data in S3 AND Snowflake. Double the cost, double the complexity, constant sync issues.

**Data Lakehouse = the bridge.** Open table formats (Iceberg, Delta Lake, Hudi) add warehouse capabilities (ACID, schema, time travel) directly on top of lake storage (S3 Parquet files). Now one copy of data serves both SQL analysts AND ML engineers.

**Our pipeline implements all three:**
- **Data Lake:** S3 stores raw JSON from Lambda. Cheap, durable, schema-less landing zone.
- **Data Warehouse:** Snowflake stores structured tables (RAW → STAGING → INTERMEDIATE). Schema-enforced, fast SQL, RBAC.
- **Data Lakehouse:** Mart tables are Snowflake-managed Iceberg tables. Data is physically stored as Parquet on S3 with Iceberg metadata. Queryable by Snowflake AND external engines (Spark, Trino, DuckDB). ACID transactions, time travel, schema evolution — all on S3.

---

### Q10. Your pipeline uses ELT. The CTO says: "I read that ETL is better for data security. We might have PII in future sensor data — should we switch to ETL?" How do you respond?

**Answer:**

"You're right that PII should be masked before it enters the warehouse — that's a legitimate ETL use case. But we don't need to switch our entire pipeline to ETL. The answer is a **hybrid approach.**"

**What stays ELT (most of the pipeline):**
- Sensor readings (temperature, humidity, pressure, GPS) have no PII. Loading raw JSON into Snowflake and transforming with dbt is the right pattern. Keeps business logic in SQL, version-controlled, easy to debug and iterate.

**What gets an ETL layer (PII only):**
- If we add operator names, email addresses, or phone numbers to device metadata, we add a **light ETL step in Lambda** that masks PII before writing to S3:
  ```python
  reading['operator_email'] = hash_pii(reading['operator_email'])
  reading['operator_name'] = mask_name(reading['operator_name'])
  ```
- The raw data in S3 and Snowflake never contains plaintext PII. Compliance met.
- Alternatively, use Snowflake's **Dynamic Data Masking** — PII is stored but masked at query time based on the user's role. `IOT_READER` sees `***@***.com`, `IOT_ADMIN` sees the real email. No ETL change needed.

**The principle:** ETL for data protection (PII masking, GDPR/HIPAA compliance). ELT for everything else (business logic, aggregation, quality checks). Don't move all your transformation logic into Lambda just because one field needs masking.

---

### Q11. Explain ACID transactions. Give me a scenario from your pipeline where each property matters. Then tell me: does S3 provide ACID? What changes that?

**Answer:**

**Atomicity — All or nothing.**
Our `COPY INTO` loads 5 JSON files from S3 into Snowflake. If file #3 has a parse error (with `ON_ERROR = 'ABORT_STATEMENT'`), the entire operation rolls back — 0 files loaded, not 2. Without atomicity, we'd have partial data: files 1-2 loaded, 3-5 missing. Downstream aggregations would be silently wrong.

**Consistency — Data always in a valid state.**
Snowflake enforces column types and NOT NULL constraints. If somehow a VARIANT field can't be parsed, `TRY_CAST` returns NULL rather than crashing. The database never enters an impossible state — every row in `stg_sensor_readings` has valid types or explicit NULLs that our validation layer catches.

**Isolation — Concurrent operations don't interfere.**
At 14:00, Airflow runs `COPY INTO` (writing new data). At the same time, an analyst runs `SELECT COUNT(*) FROM fct_hourly_readings`. Snowflake's MVCC (Multi-Version Concurrency Control) gives the analyst a consistent snapshot from before the write started. They see either all new rows or none — never a partial load.

**Durability — Once committed, data survives crashes.**
After `COPY INTO` commits, the data is persisted. Even if Snowflake's compute cluster crashes 1 second later, the data is safe in Snowflake's storage layer. We don't need to re-run the load.

**Does S3 provide ACID?** No. S3 gives you eventual consistency (now strong consistency for individual objects since 2020), but no transactions across multiple files. If Lambda writes 5 files and crashes after file 3, you have 3 files and no rollback mechanism. No isolation — two concurrent writers can produce an inconsistent state.

**What changes that?** Open table formats — Iceberg, Delta Lake, Hudi. They add a metadata layer on top of S3 that provides ACID. Iceberg uses atomic metadata commits: a write creates new Parquet files + a new snapshot pointing to them. If the write fails, the old snapshot still points to the old files. Readers always see a consistent state. That's why our mart layer uses Iceberg — it gives us ACID on S3.

---

### Q12. What is a surrogate key, and why does your `dim_devices` need one? A colleague says "we should just use `device_id` as the primary key everywhere — it's more readable." Convince them otherwise.

**Answer:**

A surrogate key is a system-generated identifier (integer or hash) that replaces the business/natural key as the primary key. `device_key = 1` instead of `device_id = 'DEV_001'`.

**Why `device_id` alone doesn't work — SCD Type 2:**

Our `dim_devices` tracks firmware history. When DEV_001 updates from v1.0 to v2.0:
```
device_key | device_id | firmware | valid_from | valid_to   | is_current
1          | DEV_001   | v1.0     | 2025-01-01 | 2025-06-01 | false
2          | DEV_001   | v2.0     | 2025-06-01 | NULL       | true
```

`DEV_001` appears twice. It can't be a primary key. The surrogate key gives each historical version a unique identity. Fact tables join on `device_key`, so a reading from March correctly joins to the v1.0 row, and a reading from July joins to v2.0.

**Three more reasons:**

1. **Source system changes.** If the IoT vendor renumbers devices from "DEV_001" to "DEVICE-001", every fact table using `device_id` as FK would break. Surrogate keys insulate the warehouse from upstream changes.

2. **Multi-source integration.** If we acquire a second fleet with its own "DEV_001", natural keys collide. Surrogate keys don't.

3. **Performance.** Integer joins (`WHERE device_key = 1`) are faster than string joins (`WHERE device_id = 'DEV_001'`) on large fact tables with billions of rows. Integer comparison is a single CPU instruction; string comparison checks character by character.

**Concession to readability:** Keep `device_id` as a column in `dim_devices` for human lookups. But the FK relationship from fact to dimension uses the surrogate key. Best of both worlds.

---

### Q13. You have `fct_hourly_readings` with `avg_temperature`. Is temperature an additive, semi-additive, or non-additive fact? Why does this distinction matter for BI tools? Give an example of each type from your pipeline.

**Answer:**

`avg_temperature` is **non-additive**. You cannot sum averages and get a meaningful result. If Device A averaged 20°C and Device B averaged 25°C, the fleet average is NOT 45°C — it's 22.5°C (you must average, not sum).

**Why this matters for BI tools:**
BI tools (Tableau, Looker) let users drag-and-drop metrics and dimensions. If a metric is tagged as "additive," the tool will SUM it when aggregating across dimensions. If an analyst drags `avg_temperature` onto a dashboard grouped by cluster, and the BI tool SUMs instead of AVGs, the number is garbage. The distinction tells the tool which aggregation function is valid.

**Examples from our pipeline:**

| Type | Metric | Example | Can SUM across... |
|------|--------|---------|-------------------|
| **Additive** | `reading_count` | 12 readings this hour + 15 next hour = 27 total | All dimensions (time, device, cluster) |
| **Additive** | `anomaly_count` | 3 anomalies on Device A + 2 on Device B = 5 total | All dimensions |
| **Semi-additive** | `battery_pct` | Device A at 80%, Device B at 60%. Can average across devices (70%). But can't sum across time — battery at 2pm + battery at 3pm = meaningless | Some dimensions (devices), not others (time) |
| **Non-additive** | `avg_temperature` | Must re-average, never sum | No dimensions — must always use AVG |
| **Non-additive** | `quality_score` | 95% quality + 80% quality ≠ 175%. Must average or recalculate | No dimensions |

**Design implication:** Our `fct_hourly_readings` stores `reading_count` alongside `avg_temperature` specifically so you CAN recompute accurate averages at higher grain levels: `SUM(avg_temperature * reading_count) / SUM(reading_count)` = weighted average. This is a standard dimensional modeling technique.

---

### Q14. Your intermediate layer has a quarantine pattern — bad records go to `int_quarantined_readings` instead of being dropped. The PM says "just filter them out, why keep garbage data?" Defend the quarantine pattern.

**Answer:**

Five reasons:

1. **Debugging.** When quality_score drops from 95 to 60, the first question is "what went wrong?" Quarantined records have the original payload + an array of rejection reason codes (`['NULL_TEMPERATURE', 'OUT_OF_RANGE_PRESSURE']`). Without them, you're guessing.

2. **Recovery.** If the validation rule itself was wrong (threshold set too tight, timezone conversion bug), quarantined records can be reprocessed. Just fix the rule, re-run dbt. If you dropped them, the data is gone — you'd need to re-extract from S3 or Lambda.

3. **Metrics and trending.** `fct_data_quality` tracks null %, OOR %, dupe % per batch over time. These metrics come from comparing quarantined count vs total count. Drop the bad records and you can't compute quality scores.

4. **Compliance.** In regulated industries, you must prove you didn't silently discard data. An auditor asks "how many records did you reject last month and why?" — quarantine table gives an instant answer.

5. **Root cause analysis.** Patterns in quarantined data reveal upstream issues. "All NULL temperature readings are from DEV_041 through DEV_050" → the outdoor cluster has a sensor hardware issue. "All out-of-range pressure readings happen at 3am" → a firmware bug during overnight calibration. You can't see these patterns if you just filter and forget.

**The cost:** Storage for quarantined records. At our scale (14,400 readings/day, ~5% quarantined = 720 rows/day), it's negligible. Even at 100x scale, it's pennies. The debugging value vastly outweighs the storage cost.

---

### Q15. Data Vault vs Star Schema. When would you choose Data Vault over what you built? Be specific — what about your project would need to change to justify Data Vault? What's the cost of that choice?

**Answer:**

**What would need to change to justify Data Vault:**

1. **Multiple source systems for the same entities.** Currently, device data comes from one source (Lambda). If we added a second fleet vendor with a different device ID format, a maintenance system (ServiceNow) tracking repairs, and a procurement system (SAP) tracking purchases — all referencing "devices" differently — Data Vault's hub pattern handles this. `Hub_Device` has one row per business key, each source writes its own satellite independently.

2. **10+ source systems with frequent changes.** Data Vault's insert-only pattern means adding a new source never breaks existing loads. Each Hub/Link/Satellite loads independently. In Star Schema, adding a source means modifying the ETL for existing dimension tables.

3. **Full audit trail requirement.** Regulated industry (banking, healthcare) where you must prove what data came from which source, when, and track every change. Data Vault's satellite pattern gives this automatically — every change is a new row with `load_ts` and `record_source`.

4. **Large team (5+ data engineers).** Data Vault enables parallel development — each engineer loads a different source into hubs/satellites independently, no merge conflicts.

**The cost of choosing Data Vault:**

- **Complexity.** Our pipeline goes from ~15 dbt models to ~40+ (hubs, links, satellites, PITs, bridges, plus mart layer on top). Data Vault is never the final query layer — analysts still need Star Schema marts built on top.
- **Query performance.** An analyst question like "average temperature by cluster" goes from 1 JOIN (fact → dim_devices) to 4+ JOINs (PIT → hub_device → sat_device_details → link_device_cluster → hub_cluster). Without PIT/Bridge tables, it's unusable.
- **Team skill requirement.** Data Vault has its own terminology (hubs, links, satellites, hashdiff, effectivity satellites, multi-active satellites). Ramping up takes weeks.
- **Tooling.** You'd want AutomateDV (dbt package) or similar to generate boilerplate. Manual Data Vault modeling is error-prone.

**Bottom line:** Our project has 1 source system, 50 devices, 1 data engineer. Star Schema is the right call. Data Vault would be justified at enterprise scale (10+ sources, 5+ engineers, audit requirements).

---

## Round 3: Operational & Debugging

### Q16. Your Airflow scheduler shows "unhealthy" and DAGs are being deactivated. Walk me through your debugging process step by step. What do you check first, second, third?

**Answer:**

**Step 1: Check scheduler logs.**
```bash
docker logs airflow-scheduler --tail 100
```
Looking for: `Killing DAGFileProcessorProcess` (OOM/timeout), `ERROR` lines, `deactivated` messages. This tells me if DAGs are failing to parse or if the scheduler process itself is crashing.

**Step 2: Check resource usage.**
```bash
docker stats --no-stream   # CPU and memory per container
free -h                     # Host-level memory
```
If the scheduler is at 90%+ memory, it's an OOM issue. This is exactly what happened with Cosmos — each DAG parse imported dbt-core (~1GB), exceeding our 2GB instance.

**Step 3: Check the specific error in file processor logs.**
```bash
docker logs airflow-scheduler 2>&1 | grep -E 'Killing|ERROR|deactivated'
```
- `Killing DAGFileProcessorProcess` → DAG file takes too long to parse. Fix: increase `DAG_FILE_PROCESSOR_TIMEOUT`, reduce parsing frequency, or use Cosmos CUSTOM load mode.
- `ModuleNotFoundError` → missing Python dependency. Fix: add to requirements.txt, rebuild image.
- `SyntaxError` in DAG file → bad code deployed. Fix: git revert.
- `deactivated` → scheduler couldn't parse the DAG and removed it. It'll come back once the file parses successfully.

**Step 4: Check Airflow metadata DB.**
```bash
docker exec airflow-scheduler airflow dags list
```
If DAGs are missing from the list, the file processor is failing. If they're listed but paused, it's a different issue.

**Step 5: Check if it's a one-time or recurring issue.** Look at the scheduler healthcheck definition. Our healthcheck runs `airflow jobs check --job-type SchedulerJob` — if the scheduler loop is stuck or slow, this times out and Docker marks it unhealthy. The scheduler might still be "working," just slowly.

**Step 6: If nothing obvious, restart with fresh state.**
```bash
docker compose down && docker compose up -d
```
Nuclear option, but sometimes a stuck process or leaked file handle needs a clean restart.

---

### Q17. It's Monday morning. Your pipeline didn't run all weekend (EC2 was stopped). How does the pipeline recover? What makes this possible without manual intervention? What if Snowflake was also down?

**Answer:**

**Recovery is automatic. Here's why:**

1. **Lambda kept running.** EventBridge triggers Lambda independently of Airflow. All weekend, Lambda generated hourly JSON files and wrote them to S3. 48 hours × 1 file/hour = 48 files sitting in S3.

2. **Start EC2, Airflow comes up.** The DAG has `catchup=False`, so it doesn't try to replay 48 individual hourly runs. It just runs once NOW.

3. **COPY INTO catches up.** Snowflake's `COPY INTO` is idempotent — it tracks which files have already been loaded via metadata. When it runs Monday morning, it sees 48 new files and loads them all in one go. Already-loaded files from before the weekend are skipped automatically.

4. **dbt transforms run on all new data.** The incremental models process everything loaded since their last run. One dbt run processes 48 hours of data. No backfill needed.

**What makes this possible:**
- **Decoupled producer/consumer** — Lambda doesn't depend on Airflow
- **Idempotent COPY INTO** — safe to run anytime, loads only new files
- **catchup=False** — no wasted runs for missed schedules
- **Incremental dbt models** — process all new data regardless of gap size

**What if Snowflake was also down?**
- S3 data is safe (Lambda wrote to S3, not Snowflake). Nothing lost.
- When Snowflake comes back, `COPY INTO` works the same way — loads all unprocessed files.
- The only scenario where we lose data: if S3 itself was down when Lambda tried to write. But S3 has 99.999999999% durability (11 nines), so this is effectively impossible.

---

### Q18. Explain idempotency. Why is it the most important property of a data pipeline? Give 3 examples from your pipeline — one that IS idempotent, one that could NOT be if designed wrong, and how you'd fix it.

**Answer:**

**Idempotency:** Running an operation once or N times produces the same result. No duplicates, no side effects, same final state.

**Why it's the #1 property:** Airflow tasks retry on failure. Networks are unreliable. Schedulers can double-fire. Humans click "Run" twice. If your pipeline isn't idempotent, every retry creates duplicates, every failure leaves partial state, and every recovery requires manual cleanup.

**Example 1 — IDEMPOTENT: Snowflake COPY INTO.**
```sql
COPY INTO sensor_readings FROM @s3_stage;
```
Run it once: loads 5 new files. Run it again immediately: loads 0 files (Snowflake remembers). Run it 10 times: same result as running it once. This is why our recovery after downtime is automatic.

**Example 2 — NOT IDEMPOTENT if designed wrong: Loading without dedup.**
```sql
-- BAD: plain INSERT from staging to intermediate
INSERT INTO int_readings_enriched
SELECT * FROM stg_sensor_readings WHERE loaded_at > '2026-04-01';
```
If this task retries, it inserts the same rows again → duplicates. Our fix: dbt incremental model with `unique_key`:
```sql
-- GOOD: dbt incremental with merge strategy
{{ config(materialized='incremental', unique_key='reading_id') }}
-- MERGE INTO: upserts on reading_id — running twice = same result
```

**Example 3 — IDEMPOTENT: dbt run --full-refresh.**
```sql
-- dbt full refresh drops and recreates the table
-- Run once: table has 100K rows
-- Run again: table still has 100K rows (same source data)
```
Full refresh is inherently idempotent because it starts clean every time. The trade-off is performance (rebuilds everything), which is why we use incremental for large tables and full-refresh for small ones.

---

### Q19. Your `fct_data_quality` shows quality_score dropped from 95 to 60 overnight. Walk me through your investigation. What queries do you run? What's your escalation path?

**Answer:**

**Step 1: Identify when and what.**
```sql
SELECT batch_ts, quality_score, null_pct, oor_pct, duplicate_pct, quarantined_count
FROM fct_data_quality
WHERE quality_score < 70
ORDER BY batch_ts DESC
LIMIT 20;
```
This tells me: is it one bad batch or a sustained drop? Which quality dimension is failing — nulls? out-of-range? duplicates?

**Step 2: Examine quarantined records.**
```sql
SELECT rejection_reasons, COUNT(*) AS cnt
FROM int_quarantined_readings
WHERE quarantined_at > DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY rejection_reasons
ORDER BY cnt DESC;
```
If 80% of rejections are `NULL_TEMPERATURE`, I know the specific failure mode.

**Step 3: Narrow down to devices.**
```sql
SELECT device_id, COUNT(*) AS bad_readings
FROM int_quarantined_readings
WHERE quarantined_at > DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY device_id
ORDER BY bad_readings DESC;
```
If all bad readings come from DEV_041–DEV_050 (outdoor cluster), it's a hardware or environmental issue.

**Step 4: Check if the source data changed.**
```sql
SELECT source_file, COUNT(*), AVG(CASE WHEN raw_data:temperature IS NULL THEN 1 ELSE 0 END) AS null_rate
FROM raw.sensor_readings
WHERE loaded_at > DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY source_file
ORDER BY null_rate DESC;
```
If null_rate is high in the raw data, the problem is upstream (Lambda error profile or actual sensor failure).

**Step 5: Check Lambda error profile.**
```sql
SELECT raw_data:error_profile::STRING, COUNT(*)
FROM raw.sensor_readings
WHERE loaded_at > DATEADD(hour, -24, CURRENT_TIMESTAMP())
GROUP BY 1;
```
If someone changed the EventBridge target to `"high"` or `"chaos"` error profile, that explains everything.

**Escalation path:**
- Error profile was changed → revert EventBridge target, notify team
- Specific device cluster failing → hardware alert to operations team
- All devices affected → check Lambda code deployment, check sensor firmware update rollout
- Validation rule too strict (false positives) → review thresholds in `sensor_thresholds` seed, adjust, re-run dbt

---

### Q20. The Snowflake bill doubled this month. Where do you look first? Name 5 specific cost optimization strategies and which ones you've already implemented.

**Answer:**

**Where to look first:**
```sql
-- Top cost drivers by warehouse
SELECT warehouse_name,
       SUM(credits_used) AS total_credits,
       COUNT(DISTINCT query_id) AS query_count
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time > DATEADD(month, -1, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- Longest/most expensive queries
SELECT query_id, query_text, warehouse_name,
       total_elapsed_time/1000 AS seconds,
       credits_used_cloud_services
FROM snowflake.account_usage.query_history
WHERE start_time > DATEADD(month, -1, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 20;
```

**5 cost optimization strategies:**

1. **Auto-suspend warehouse (IMPLEMENTED).** `ALTER WAREHOUSE IOT_WH SET AUTO_SUSPEND = 60`. Warehouse shuts down after 60 seconds idle. Without this, an XS warehouse running 24/7 costs ~$1,400/month. With auto-suspend and our hourly workload, it's ~$30/month.

2. **Right-size warehouse (IMPLEMENTED).** We use XSMALL for our workload (50 devices, 14K rows/day). One common mistake: running `dbt run` on a LARGE warehouse "just in case." An XL warehouse costs 64x more per second than XS.

3. **Clustering keys on large fact tables.** If `fct_hourly_readings` grows to billions of rows, add `CLUSTER BY (device_id, reading_hour)`. Queries filtering by device or time range scan fewer micro-partitions. Not implemented yet because our data is small.

4. **Transient tables for staging/intermediate.** Transient tables skip Snowflake's 7-day Fail-Safe, reducing storage costs. Staging data is reproducible from S3, so we don't need Fail-Safe protection on it.

5. **Result caching (FREE, automatic).** Snowflake caches query results for 24 hours. If the same dashboard query runs 100 times/day, only the first one uses compute credits. We get this for free.

**Bonus — what likely caused the doubling:**
- A warehouse left running (someone forgot auto-suspend on a new warehouse)
- A full-refresh dbt run on a large warehouse (`dbt run --full-refresh` rebuilds everything)
- Queries from a BI tool that isn't using result cache (parameterized queries with unique timestamps)
- Snowpipe running continuously when batch COPY INTO would suffice

---
