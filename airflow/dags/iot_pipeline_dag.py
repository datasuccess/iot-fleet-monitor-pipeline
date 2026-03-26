"""
IoT Fleet Monitor Pipeline DAG — Phase 3 (minimal version)

Flow: trigger_lambda → wait → load_to_snowflake → validate_load

dbt integration via Cosmos will be added in Phase 4-6.
"""

import json
import os
from datetime import datetime, timedelta

from airflow.decorators import dag, task
from airflow.models.param import Param

from helpers.lambda_utils import invoke_lambda
from helpers.snowflake_utils import run_snowflake_query


@dag(
    dag_id="iot_pipeline",
    description="IoT sensor data: Lambda → S3 → Snowflake → dbt",
    schedule="*/5 * * * *",  # Every 5 minutes (matches sensor interval)
    start_date=datetime(2026, 3, 26),
    catchup=False,
    max_active_runs=1,
    default_args={
        "owner": "data-engineering",
        "retries": 2,
        "retry_delay": timedelta(minutes=1),
    },
    params={
        "error_profile": Param(
            default="none",
            type="string",
            enum=["none", "normal", "high", "chaos"],
            description="Error injection profile for data generation",
        ),
    },
    tags=["iot", "pipeline"],
)
def iot_pipeline():

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
            raise ValueError("No rows loaded in the last 10 minutes!")

        return {"rows_loaded_recent": row_count, "status": "validated"}

    # DAG flow: trigger → load → validate
    lambda_result = trigger_lambda()
    load_result = load_to_snowflake(lambda_result)
    validate_load(load_result)


iot_pipeline()
