# Interview Q&A — IoT Fleet Monitor Pipeline

## Round 1: Architecture & Design Decisions

### Q1. Walk me through the end-to-end data flow of this pipeline. Start from when a sensor reading is generated and end at when a business user queries the fleet overview report. Hit every layer.

**Your answer:**

---

### Q2. You decoupled Lambda from Airflow — Lambda runs on EventBridge independently, and the Airflow DAG is a "consumer." Why this pattern instead of having Airflow trigger Lambda directly? What problem does it solve?

**Your answer:**

---

### Q3. Why did you choose Snowflake VARIANT columns for the raw layer instead of parsing JSON on ingestion? What trade-off are you making?

**Your answer:**

---

### Q4. Your mart tables are Snowflake-managed Iceberg tables stored as Parquet on S3. Why not just use regular Snowflake tables? When would you *not* use Iceberg?

**Your answer:**

---

### Q5. You're running Airflow on a t4g.small (2GB RAM) EC2 instance with LocalExecutor. What are the limits of this setup, and at what point would you need to change the architecture?

**Your answer:**

---
