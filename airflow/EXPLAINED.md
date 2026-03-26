# Phase 3: Airflow DAG — Code Explained

## 1. TaskFlow API (@task decorator)

```python
@task()
def trigger_lambda(**context) -> dict:
    response = invoke_lambda(...)
    return response

@task()
def load_to_snowflake(lambda_response: dict) -> dict:
    ...
```

**Old way** (Airflow 1.x): Define PythonOperator, pass callable, manually push/pull XComs.

**TaskFlow** (Airflow 2.x+): Decorate functions with `@task()`. Return values automatically become XComs. Pass them as function arguments — Airflow handles serialization.

```python
# This creates the DAG dependency AND passes data:
lambda_result = trigger_lambda()
load_result = load_to_snowflake(lambda_result)  # Receives lambda_result via XCom
```

---

## 2. DAG Decorator

```python
@dag(
    schedule="*/5 * * * *",     # Cron: every 5 minutes
    catchup=False,               # Don't backfill past runs
    max_active_runs=1,           # Only one run at a time
    params={...},                # Runtime parameters
)
def iot_pipeline():
    ...

iot_pipeline()  # Must call to register the DAG
```

`catchup=False` is important — without it, Airflow would try to run every 5-minute interval since `start_date` (potentially thousands of runs).

---

## 3. Airflow Params

```python
params={
    "error_profile": Param(
        default="none",
        type="string",
        enum=["none", "normal", "high", "chaos"],
    ),
}
```

Params let you **change behavior at runtime** without code changes. In the Airflow UI:
1. Click "Trigger DAG w/ config"
2. Select error_profile from dropdown
3. Run

The DAG reads it via `context["params"]["error_profile"]`.

This is how the 5-Day Production Run works — same DAG, different params each day.

---

## 4. Lambda Invocation Helper (lambda_utils.py)

```python
config = Config(
    retries={"max_attempts": 3, "mode": "adaptive"},
    read_timeout=120,
)
client = boto3.client("lambda", config=config)
response = client.invoke(
    FunctionName=function_name,
    InvocationType="RequestResponse",  # Synchronous
    Payload=json.dumps(payload),
)
```

Key decisions:
- **RequestResponse**: Wait for Lambda to finish (vs. "Event" which is fire-and-forget)
- **Adaptive retry**: boto3 automatically retries with exponential backoff on throttling
- **read_timeout=120**: Lambda has 60s timeout, we wait 120s to be safe

---

## 5. Snowflake COPY INTO (snowflake_utils.py)

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

- `$1` — The entire JSON object (loaded as VARIANT)
- `METADATA$FILENAME` — Snowflake auto-populates this with the S3 file path
- `ON_ERROR = 'CONTINUE'` — Skip bad files, don't fail the whole load
- `PATTERN` — Only load .json files (ignore any other files in the stage)

Snowflake tracks which files have already been loaded — running COPY INTO twice won't duplicate data.

---

## 6. Docker Compose Volumes

```yaml
volumes:
  - ./dags:/opt/airflow/dags
  - ../dbt/iot_pipeline:/opt/airflow/dbt/iot_pipeline
```

DAGs directory is mounted so you can edit DAGs without rebuilding the container. The dbt project is also mounted — Cosmos needs access to dbt models to render them as Airflow tasks.

---

## 7. Environment Variables for Credentials

```yaml
SNOWFLAKE_ACCOUNT: ${SNOWFLAKE_ACCOUNT:-}
AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID:-}
```

The `${VAR:-}` syntax means: use the env var if set, otherwise empty string. Values come from `airflow/.env` (not committed to git).

In production, you'd use:
- AWS Secrets Manager or SSM Parameter Store
- Airflow Connections (stored encrypted in Airflow's DB)
- HashiCorp Vault

For learning, env vars are fine.

---

## 8. Astronomer Cosmos (Phase 4+)

```python
from cosmos import DbtTaskGroup, ProjectConfig, ProfileConfig

dbt_tasks = DbtTaskGroup(
    project_config=ProjectConfig(dbt_project_path="/opt/airflow/dbt/iot_pipeline"),
    profile_config=ProfileConfig(...),
)
```

Cosmos turns each dbt model into an individual Airflow task. Benefits:
- See dbt model dependencies in Airflow's graph view
- Retry individual models (not the whole dbt run)
- dbt test results visible per-model
- Full observability without leaving Airflow UI

This will be wired in after we build the dbt models in Phase 4-5.

---

## DAG Flow (Phase 3)

```
trigger_lambda → load_to_snowflake → validate_load
     |                  |                  |
  Invoke Lambda    COPY INTO from     Count rows loaded
  with error       S3 to Snowflake    in last 10 minutes
  profile param    RAW schema         (fail if 0)
```
