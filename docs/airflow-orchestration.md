# Phase 6 — Full Airflow Orchestration Explained

## Astronomer Cosmos (dbt + Airflow Integration)

### The Problem
Without Cosmos, you'd run dbt as a single BashOperator (`dbt run`). If model #15 out of 20 fails, you can't see which one failed in the Airflow UI — you'd have to dig through logs.

### The Solution
Cosmos **renders each dbt model as an individual Airflow task**. Your DAG graph shows:
```
stg_sensor_readings → int_readings_deduped → int_readings_validated → fct_hourly_readings
                                           → int_readings_enriched  → fct_device_health
                                           → int_quarantined_readings
```

If `int_readings_validated` fails, you see it immediately in the Airflow UI. You can retry just that task.

### Key Cosmos Components

```python
from cosmos import DbtTaskGroup, ProjectConfig, ProfileConfig, RenderConfig

dbt_tasks = DbtTaskGroup(
    project_config=ProjectConfig("/opt/airflow/dbt/iot_pipeline"),
    profile_config=ProfileConfig(...),
    render_config=RenderConfig(select=["path:models/staging", "path:models/intermediate"]),
)
```

- **ProjectConfig**: Points to your dbt project directory
- **ProfileConfig**: How to connect to Snowflake (profiles.yml path + target name)
- **RenderConfig**: Which dbt models to include (uses dbt selector syntax)
- **ExecutionConfig**: Where the dbt binary lives inside the container

### How It Works Under the Hood
1. Cosmos reads your `dbt_project.yml` and model files at DAG parse time
2. It builds a dependency graph from `{{ ref() }}` calls
3. Each model becomes a task, each `ref()` becomes a task dependency
4. At runtime, each task runs `dbt run --select model_name`

---

## @task.branch — Conditional Routing

```python
@task.branch()
def branch_on_quality(validation_result):
    if validation_result["rows_loaded_recent"] > 0:
        return "dbt_transform"  # task_id to run
    return "skip_dbt"           # alternative task_id
```

**How it works**: Returns the task_id(s) of downstream tasks that should run. All other branches are skipped.

**Why use it here?** If the load step found 0 rows (Lambda failed, S3 empty), there's no point running dbt — it would process nothing. Branch skips dbt and goes straight to logging.

---

## Trigger Rules

By default, a task only runs if ALL upstream tasks succeed. But with branching, one path is always skipped. The `log_completion` task needs a different rule:

```python
@task(trigger_rule="none_failed_min_one_success")
def log_completion():
    ...
```

| Rule | Meaning |
|------|---------|
| `all_success` (default) | All parents must succeed |
| `none_failed_min_one_success` | No parent failed, at least one succeeded (skipped is OK) |
| `all_done` | Run regardless of parent status |
| `one_success` | At least one parent succeeded |

---

## SLA (Service Level Agreement)

```python
default_args = {
    "sla": timedelta(minutes=45),
}
```

If any task takes longer than 45 minutes from the DAG's scheduled start time, Airflow fires an SLA miss callback. This doesn't stop the task — it just alerts you.

**Real-world use**: "Our pipeline must complete within 45 minutes of each hour. If it doesn't, page the on-call engineer."

---

## Airflow Params — Runtime Configuration

```python
params={
    "error_profile": Param(default="none", enum=["none", "normal", "high", "chaos"]),
    "run_dbt": Param(default=True, type="boolean"),
}
```

Params let you change DAG behavior **at trigger time** without editing code:
- In the UI: click "Trigger DAG w/ config" and fill in values
- Via CLI: `airflow dags trigger --conf '{"error_profile": "chaos"}'`

**Why `run_dbt` param?** Sometimes you want to just load data without transforming (debugging, backfill).

---

## Callbacks — Failure & Success Hooks

```python
def on_failure_callback(context):
    task_id = context["task_instance"].task_id
    exception = context.get("exception")
    # Log, send Slack message, page on-call, etc.
```

Callbacks fire after specific events:
- `on_failure_callback`: Task failed after all retries exhausted
- `on_success_callback`: Task completed successfully
- `on_sla_miss_callback`: SLA deadline exceeded

**In production**, these would send Slack/PagerDuty alerts. Here we log them.

---

## Monitoring DAG — Separation of Concerns

The monitoring DAG runs at `:30` past each hour (main pipeline runs at `:00`). This ensures it checks data **after** the pipeline has finished.

**Why a separate DAG?**
- Different schedule, different owner, different failure handling
- Monitoring should work even if the pipeline DAG is broken
- Clear separation: pipeline = produce data, monitoring = verify data

### Freshness Check
```sql
SELECT DATEDIFF(MINUTE, MAX(loaded_at), CURRENT_TIMESTAMP())
FROM IOT_PIPELINE.RAW.sensor_readings
```
If data is > 2 hours old, something is wrong upstream.

### Quality Check
Queries `fct_data_quality` for the latest batch's quality score. Below 80 = warning.

### Anomaly Spike Check
Counts anomalies in the last hour. A sudden spike (> 50) might indicate a real incident vs. sensor drift.

---

## Custom S3 Sensor

```python
class S3FileCountSensor(BaseSensorOperator):
    def poke(self, context):
        # List S3 objects, return True if enough files exist
```

**Sensors** are special operators that **wait** for a condition. They "poke" (check) at intervals:
- `poke_interval`: How often to check (default 60s)
- `timeout`: How long to wait before failing
- `mode`: `poke` (holds a worker slot) vs `reschedule` (releases slot between checks)

**Use case**: Wait for Lambda to write files to S3 before starting the load step.

---

## Key Patterns

1. **Branch + trigger_rule**: Conditional execution without breaking the DAG
2. **Cosmos over BashOperator**: Per-model visibility in Airflow UI
3. **Params over hardcoded config**: Runtime flexibility without code changes
4. **Separate monitoring DAG**: Independent observability
5. **Callbacks for alerting**: Don't rely on checking the UI manually
