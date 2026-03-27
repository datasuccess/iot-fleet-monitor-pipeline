"""
IoT Fleet Monitor Pipeline DAG - Phase 6
Uses TaskFlow API with Cosmos dbt integration.

Flow: trigger_lambda -> load_to_snowflake -> validate_load -> branch_on_quality
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

from helpers.lambda_utils import invoke_lambda
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
    description="IoT sensor data: Lambda -> S3 -> Snowflake -> dbt (Cosmos)",
    schedule="0 * * * *",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["iot", "pipeline", "cosmos"],
    params={
        "error_profile": Param(
            default="none",
            type="string",
            enum=["none", "normal", "high", "chaos"],
            description="Error injection profile for data generation",
        ),
        "run_dbt": Param(
            default=True,
            type="boolean",
            description="Whether to run dbt models after loading",
        ),
    },
    on_success_callback=on_success_callback,
)
def iot_pipeline():
    """End-to-end IoT fleet monitoring pipeline with dbt via Cosmos."""

    @task()
    def trigger_lambda(**context) -> dict:
        """Invoke Lambda to generate sensor data and write to S3."""
        error_profile = context["params"]["error_profile"]

        response = invoke_lambda(
            function_name="iot-fleet-data-generator",
            payload={"error_profile": error_profile},
        )

        print(f"Lambda response: {json.dumps(response, indent=2)}")
        return response

    @task()
    def load_to_snowflake(lambda_response: dict) -> dict:
        """COPY INTO from S3 stage to Snowflake RAW table."""
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
        print(f"COPY INTO result: {result}")

        return {
            "status": "loaded",
            "s3_path": lambda_response.get("body", {}).get("s3_path", ""),
        }

    @task()
    def validate_load(load_result: dict) -> dict:
        """Validate that data was loaded successfully."""
        count_sql = """
            SELECT COUNT(*) AS total_rows
            FROM IOT_PIPELINE.RAW.sensor_readings
            WHERE loaded_at >= DATEADD(MINUTE, -10, CURRENT_TIMESTAMP());
        """

        result = run_snowflake_query(count_sql)
        row_count = result[0][0] if result else 0
        print(f"Rows loaded in last 10 minutes: {row_count}")

        if row_count == 0:
            print("WARNING: No rows loaded in the last 10 minutes")

        return {"row_count": row_count, "is_valid": row_count > 0}

    @task.branch()
    def branch_on_quality(validation_result: dict, **context) -> str:
        """Branch based on data quality and run_dbt parameter."""
        row_count = validation_result.get("row_count", 0)
        run_dbt = context["params"].get("run_dbt", True)

        if row_count > 0 and run_dbt:
            print("Data valid and run_dbt=True -> running dbt models")
            return "start_dbt"
        else:
            print(f"Skipping dbt (row_count={row_count}, run_dbt={run_dbt})")
            return "skip_dbt"

    @task()
    def skip_dbt():
        """Placeholder task when dbt is skipped."""
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
    lambda_result = trigger_lambda()
    load_result = load_to_snowflake(lambda_result)
    validation_result = validate_load(load_result)
    branch_result = branch_on_quality(validation_result)

    # EmptyOperator as gateway — branch can target this by task_id
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
