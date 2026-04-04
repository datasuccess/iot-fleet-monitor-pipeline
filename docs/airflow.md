# Airflow — DAG Design, Orchestration & Testing

## Core Concepts

### TaskFlow API (@task decorator)

```python
@task()
def trigger_lambda(**context) -> dict:
    response = invoke_lambda(...)
    return response

@task()
def load_to_snowflake(lambda_response: dict) -> dict:
    ...
```

**Old way** (Airflow 1.x): PythonOperator, manual XCom push/pull.
**TaskFlow** (2.x+): Decorate with `@task()`, return values auto-become XComs, pass as function arguments.

```python
lambda_result = trigger_lambda()
load_result = load_to_snowflake(lambda_result)  # Receives via XCom automatically
```

### DAG Decorator

```python
@dag(
    schedule="*/5 * * * *",     # Every 5 minutes
    catchup=False,               # Don't backfill past runs
    max_active_runs=1,           # One run at a time
    params={...},                # Runtime parameters
)
def iot_pipeline():
    ...

iot_pipeline()  # Must call to register
```

`catchup=False` prevents Airflow from running every missed interval since `start_date`.

### Airflow Params — Runtime Configuration

```python
params={
    "error_profile": Param(default="none", enum=["none", "normal", "high", "chaos"]),
    "run_dbt": Param(default=True, type="boolean"),
}
```

Change behavior **at trigger time** without code changes:
- UI: "Trigger DAG w/ config" → fill values
- CLI: `airflow dags trigger --conf '{"error_profile": "chaos"}'`

---

## Lambda Integration (lambda_utils.py)

```python
config = Config(retries={"max_attempts": 3, "mode": "adaptive"}, read_timeout=120)
client = boto3.client("lambda", config=config)
response = client.invoke(
    FunctionName=function_name,
    InvocationType="RequestResponse",  # Synchronous (wait for result)
    Payload=json.dumps(payload),
)
```

- **RequestResponse**: Wait for Lambda to finish (vs "Event" = fire-and-forget)
- **Adaptive retry**: Exponential backoff on throttling
- **read_timeout=120**: Lambda has 60s timeout, we wait 120s

## Snowflake COPY INTO (snowflake_utils.py)

```sql
COPY INTO sensor_readings (raw_data, loaded_at, source_file)
FROM (
    SELECT $1, CURRENT_TIMESTAMP(), METADATA$FILENAME
    FROM @raw_sensor_stage
)
FILE_FORMAT = json_sensor_format
PATTERN = '.*\.json'
ON_ERROR = 'CONTINUE';
```

- `$1` — Entire JSON as VARIANT
- `METADATA$FILENAME` — S3 file path auto-populated
- `ON_ERROR = 'CONTINUE'` — Skip bad files
- Snowflake tracks loaded files — COPY INTO won't duplicate

---

## Astronomer Cosmos (dbt + Airflow)

### The Problem
Without Cosmos, dbt runs as a single BashOperator. If model #15 of 20 fails, you dig through logs.

### The Solution
Cosmos renders each dbt model as an individual Airflow task:
```
stg_sensor_readings → int_readings_deduped → int_readings_validated → fct_hourly_readings
                                           → int_readings_enriched  → fct_device_health
                                           → int_quarantined_readings
```

### Key Components
```python
from cosmos import DbtTaskGroup, ProjectConfig, ProfileConfig, RenderConfig

dbt_tasks = DbtTaskGroup(
    project_config=ProjectConfig("/opt/airflow/dbt/iot_pipeline"),
    profile_config=ProfileConfig(...),
    render_config=RenderConfig(select=["path:models/staging", "path:models/intermediate"]),
)
```

### How It Works
1. Reads `dbt_project.yml` and model files at DAG parse time
2. Builds dependency graph from `{{ ref() }}` calls
3. Each model becomes a task, each `ref()` becomes a dependency
4. At runtime, each task runs `dbt run --select model_name`

---

## @task.branch — Conditional Routing

```python
@task.branch()
def branch_on_quality(validation_result):
    if validation_result["rows_loaded_recent"] > 0:
        return "dbt_transform"
    return "skip_dbt"
```

Returns task_id(s) to run. All other branches get skipped. If load found 0 rows, skip dbt entirely.

## Trigger Rules

| Rule | Meaning |
|------|---------|
| `all_success` (default) | All parents must succeed |
| `none_failed_min_one_success` | No parent failed, at least one succeeded (skipped OK) |
| `all_done` | Run regardless of parent status |
| `one_success` | At least one parent succeeded |

## SLA (Service Level Agreement)

```python
default_args = {"sla": timedelta(minutes=45)}
```

If any task exceeds 45 minutes from scheduled start → SLA miss callback fires (alerts, doesn't stop the task).

## Callbacks

```python
def on_failure_callback(context):
    task_id = context["task_instance"].task_id
    exception = context.get("exception")
    # Log, Slack, PagerDuty, etc.
```

- `on_failure_callback`: After all retries exhausted
- `on_success_callback`: Task completed
- `on_sla_miss_callback`: SLA exceeded

---

## Monitoring DAG — Separation of Concerns

Runs at `:30` past each hour (main pipeline runs at `:00`). Checks data **after** pipeline finishes.

**Why separate?** Different schedule, different owner, different failure handling. Monitoring works even if the pipeline DAG is broken.

### Checks
- **Freshness**: `DATEDIFF(MINUTE, MAX(loaded_at), CURRENT_TIMESTAMP())` — alert if > 2 hours
- **Quality**: Latest batch quality score from `fct_data_quality` — warn if < 80
- **Anomaly spike**: Count in last hour — alert if > 50

## Custom S3 Sensor

```python
class S3FileCountSensor(BaseSensorOperator):
    def poke(self, context):
        # List S3 objects, return True if enough files exist
```

Sensors **wait** for a condition. `poke_interval` = check frequency, `timeout` = max wait, `mode` = `poke` (holds worker) vs `reschedule` (releases between checks).

---

## Docker Compose Setup

```yaml
volumes:
  - ./dags:/opt/airflow/dags              # Edit DAGs without rebuild
  - ../dbt/iot_pipeline:/opt/airflow/dbt/iot_pipeline  # Cosmos needs dbt access
```

Environment variables via `${VAR:-}` from `airflow/.env` (not committed).

---

## DAG Flow

```
trigger_lambda → load_to_snowflake → validate_load → branch
                                                       ├── (has_data) → dbt_staging → dbt_intermediate → dbt_marts
                                                       └── (no_data) → skip → log
```

## Key Patterns
1. **Branch + trigger_rule**: Conditional execution without breaking the DAG
2. **Cosmos over BashOperator**: Per-model visibility in Airflow UI
3. **Params over hardcoded config**: Runtime flexibility without code changes
4. **Separate monitoring DAG**: Independent observability
5. **Callbacks for alerting**: Don't rely on checking the UI manually

---

## Testing & Deployment

### Deploy to EC2

```bash
# Copy credentials (gitignored)
scp -i ~/.ssh/iot-fleet-pipeline-key.pem airflow/.env ubuntu@<IP>:/home/ubuntu/iot-pipeline/airflow/.env

# Rebuild on EC2
ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@<IP>
cd /home/ubuntu/iot-pipeline/airflow
docker compose down && docker compose build && docker compose up -d
```

### Verify

```bash
docker compose ps                    # All healthy?
docker compose logs -f airflow-scheduler  # Check for errors
```

### Trigger DAG

**UI**: Unpause → "Trigger DAG w/ config" → select error_profile → Trigger

**CLI**:
```bash
docker exec airflow-airflow-webserver-1 \
  airflow dags trigger iot_pipeline --conf '{"error_profile": "none"}'
```

### Check Results in Snowflake
```sql
SELECT COUNT(*) FROM IOT_PIPELINE.RAW.sensor_readings;
SELECT raw_data:device_id::VARCHAR, raw_data:temperature::FLOAT, loaded_at
FROM IOT_PIPELINE.RAW.sensor_readings ORDER BY loaded_at DESC LIMIT 10;
```

### Troubleshooting

| Problem | Fix |
|---------|-----|
| DAG not in UI | `airflow dags list-import-errors` |
| Task failed | `docker compose logs -f airflow-scheduler` |
| Lambda timeout | Verify AWS creds in `.env`, test Lambda directly |
| Snowflake error | Check account format, verify credentials |
