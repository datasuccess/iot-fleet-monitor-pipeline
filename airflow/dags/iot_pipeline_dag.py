"""
IoT Fleet Monitor Pipeline DAG - Decoupled Pattern

Lambda runs independently via EventBridge (producer).
This DAG is the consumer — loads whatever S3 data exists since last success.

Flow: load_new_data -> validate_load -> branch_on_quality
      -> [start_dbt -> dbt_models OR skip_dbt] -> log_completion
"""

import json
import os
from datetime import datetime, timedelta
from pathlib import Path

from airflow.decorators import dag, task
from airflow.models.param import Param
from airflow.operators.empty import EmptyOperator
from airflow.utils.trigger_rule import TriggerRule
from cosmos import (
    DbtTaskGroup,
    ExecutionConfig,
    ProfileConfig,
    ProjectConfig,
    RenderConfig,
)

from helpers.notify import on_failure_callback, on_success_callback
from helpers.snowflake_utils import run_snowflake_query

DBT_PROJECT_PATH = "/opt/airflow/dbt/iot_pipeline"
DBT_PROFILES_PATH = Path(DBT_PROJECT_PATH) / "profiles.yml"
DBT_EXECUTABLE_PATH = "/home/airflow/.local/bin/dbt"

default_args = {
    "owner": "data-engineering",
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
    "sla": timedelta(minutes=45),
    "on_failure_callback": on_failure_callback,
}


@dag(
    dag_id="iot_pipeline",
    description="IoT sensor data: S3 -> Snowflake -> dbt (Cosmos). Decoupled from Lambda.",
    schedule="0 * * * *",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["iot", "pipeline", "cosmos"],
    params={
        "run_dbt": Param(
            default=True,
            type="boolean",
            description="Whether to run dbt models after loading",
        ),
    },
    on_success_callback=on_success_callback,
)
def iot_pipeline():
    """
    Consumer DAG — loads unprocessed S3 data into Snowflake, then runs dbt.

    Lambda (producer) runs independently via EventBridge and writes to S3.
    This DAG picks up whatever data is in S3 since the last successful load.
    Snowflake COPY INTO is idempotent — already-loaded files are skipped.
    """

    @task()
    def load_new_data() -> dict:
        """
        COPY INTO from S3 stage to Snowflake RAW table.

        Snowflake tracks which files have already been loaded (metadata).
        Running COPY INTO again is safe — it only loads NEW files.
        This is the key to idempotent recovery after downtime.
        """
        copy_sql = """
            COPY INTO IOT_PIPELINE.RAW.sensor_readings (raw_data, loaded_at, source_file)
            FROM (
                SELECT
                    $1,
                    CURRENT_TIMESTAMP(),
                    METADATA$FILENAME
                FROM @IOT_PIPELINE.RAW.raw_sensor_stage
            )
            FILE_FORMAT = IOT_PIPELINE.RAW.json_sensor_format
            PATTERN = '.*\\.json'
            ON_ERROR = 'CONTINUE';
        """

        result = run_snowflake_query(copy_sql)

        # COPY INTO returns rows like: (file, status, rows_parsed, rows_loaded, ...)
        files_loaded = len(result) if result else 0
        rows_loaded = sum(row[3] for row in result) if result else 0

        print(f"COPY INTO loaded {files_loaded} new files, {rows_loaded} rows")
        print(f"Raw result: {result}")

        return {
            "files_loaded": files_loaded,
            "rows_loaded": rows_loaded,
        }

    @task()
    def validate_load(load_result: dict) -> dict:
        """Check total data in raw table and recent load results."""
        count_sql = """
            SELECT
                COUNT(*) AS total_rows,
                COUNT(DISTINCT source_file) AS total_files,
                MAX(loaded_at) AS latest_load
            FROM IOT_PIPELINE.RAW.sensor_readings;
        """

        result = run_snowflake_query(count_sql)
        total_rows = result[0][0] if result else 0
        total_files = result[0][1] if result else 0
        latest_load = result[0][2] if result else None

        new_files = load_result.get("files_loaded", 0)
        new_rows = load_result.get("rows_loaded", 0)

        print(f"Validation:")
        print(f"  New files this run: {new_files}")
        print(f"  New rows this run: {new_rows}")
        print(f"  Total rows in raw: {total_rows}")
        print(f"  Total files loaded: {total_files}")
        print(f"  Latest load: {latest_load}")

        return {
            "new_files": new_files,
            "new_rows": new_rows,
            "total_rows": total_rows,
            "has_new_data": new_rows > 0,
        }

    @task.branch()
    def branch_on_quality(validation_result: dict, **context) -> str:
        """Branch: run dbt if there's data to process."""
        has_new_data = validation_result.get("has_new_data", False)
        run_dbt = context["params"].get("run_dbt", True)

        if has_new_data and run_dbt:
            print("New data loaded and run_dbt=True -> running dbt models")
            return "start_dbt"
        elif not has_new_data:
            print("No new data found in S3 — skipping dbt")
            return "skip_dbt"
        else:
            print(f"Skipping dbt (run_dbt={run_dbt})")
            return "skip_dbt"

    @task()
    def skip_dbt():
        """No new data or dbt disabled — skip transformations."""
        print("Skipping dbt transformations")

    @task(trigger_rule=TriggerRule.NONE_FAILED_MIN_ONE_SUCCESS)
    def log_completion(**context):
        """Log pipeline completion summary."""
        dag_run = context["dag_run"]
        print("=" * 60)
        print("IoT Fleet Monitor Pipeline - Run Complete")
        print(f"  DAG Run ID: {dag_run.run_id}")
        print(f"  Logical Date: {context['logical_date']}")
        print(f"  Params: {context['params']}")
        print("=" * 60)

    # Wire up the task flow
    load_result = load_new_data()
    validation_result = validate_load(load_result)
    branch_result = branch_on_quality(validation_result)

    # EmptyOperator as gateway for branching into Cosmos task group
    start_dbt = EmptyOperator(task_id="start_dbt")

    dbt_models = DbtTaskGroup(
        group_id="dbt_models",
        project_config=ProjectConfig(
            dbt_project_path=DBT_PROJECT_PATH,
        ),
        profile_config=ProfileConfig(
            profile_name="iot_pipeline",
            profiles_yml_filepath=DBT_PROFILES_PATH,
            target_name="dev",
        ),
        render_config=RenderConfig(
            select=[
                "path:models/staging",
                "path:models/intermediate",
                "path:models/marts",
            ],
        ),
        execution_config=ExecutionConfig(
            dbt_executable_path=DBT_EXECUTABLE_PATH,
        ),
    )

    skip = skip_dbt()
    completion = log_completion()

    # Branch routes to start_dbt (gateway) or skip_dbt
    branch_result >> [start_dbt, skip]
    start_dbt >> dbt_models >> completion
    skip >> completion


iot_pipeline()
