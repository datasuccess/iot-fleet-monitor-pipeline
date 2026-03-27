"""
IoT Fleet Monitoring DAG - Phase 6
Runs 30 minutes after the main pipeline to check data freshness, quality, and anomalies.
"""

from datetime import datetime, timedelta

from airflow.decorators import dag, task

from helpers.notify import on_failure_callback
from helpers.snowflake_utils import run_snowflake_query

default_args = {
    "owner": "data-engineering",
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
    "on_failure_callback": on_failure_callback,
}


@dag(
    dag_id="iot_monitoring",
    start_date=datetime(2024, 1, 1),
    schedule="30 * * * *",
    catchup=False,
    default_args=default_args,
    tags=["iot", "monitoring"],
)
def iot_monitoring():
    """Monitor IoT pipeline health: freshness, quality, and anomalies."""

    @task()
    def check_data_freshness():
        """Check that raw data is not stale (> 2 hours old)."""
        query = """
            SELECT
                MAX(loaded_at) AS latest_load,
                DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) AS minutes_since_load
            FROM IOT_PIPELINE.RAW.sensor_readings
        """
        result = run_snowflake_query(query)
        row = result[0] if result else None

        if row is None:
            raise ValueError("No data found in IOT_PIPELINE.RAW.sensor_readings")

        latest_load = row[0]
        minutes_since = row[1]

        print(f"Latest load: {latest_load} ({minutes_since} minutes ago)")

        if minutes_since > 120:
            raise ValueError(
                f"Data is stale! Last loaded {minutes_since} minutes ago (threshold: 120 min)"
            )

        return {
            "latest_load": str(latest_load),
            "minutes_since_load": minutes_since,
            "is_fresh": minutes_since <= 120,
        }

    @task()
    def check_data_quality():
        """Check average quality score from the last batch."""
        query = """
            SELECT
                AVG(quality_score) AS avg_quality_score,
                COUNT(*) AS record_count
            FROM IOT_PIPELINE.MARTS.fct_data_quality
            WHERE batch_ts >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
        """
        result = run_snowflake_query(query)
        row = result[0] if result else None

        if row is None or row[0] is None:
            print("WARNING: No quality data found for the last batch")
            return {
                "avg_quality_score": None,
                "record_count": 0,
                "is_acceptable": False,
            }

        avg_score = float(row[0])
        record_count = row[1]

        print(f"Average quality score: {avg_score:.2f} ({record_count} records)")

        if avg_score < 80:
            print(
                f"WARNING: Quality score {avg_score:.2f} is below threshold of 80"
            )

        return {
            "avg_quality_score": avg_score,
            "record_count": record_count,
            "is_acceptable": avg_score >= 80,
        }

    @task()
    def check_anomaly_count():
        """Check the number of anomalies detected in the last hour."""
        query = """
            SELECT COUNT(*) AS anomaly_count
            FROM IOT_PIPELINE.MARTS.fct_anomalies
            WHERE detected_at >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
        """
        result = run_snowflake_query(query)
        anomaly_count = result[0][0] if result else 0

        print(f"Anomalies in last hour: {anomaly_count}")

        if anomaly_count > 50:
            print(
                f"WARNING: High anomaly count ({anomaly_count}) exceeds threshold of 50"
            )

        return {
            "anomaly_count": anomaly_count,
            "is_normal": anomaly_count <= 50,
        }

    @task()
    def generate_report(freshness, quality, anomalies):
        """Combine monitoring results into a summary report."""
        report = {
            "timestamp": str(datetime.utcnow()),
            "data_freshness": freshness,
            "data_quality": quality,
            "anomalies": anomalies,
            "overall_status": "HEALTHY"
            if (
                freshness.get("is_fresh", False)
                and quality.get("is_acceptable", False)
                and anomalies.get("is_normal", False)
            )
            else "DEGRADED",
        }

        print("=" * 60)
        print("IoT Monitoring Report")
        print("=" * 60)
        print(f"  Status: {report['overall_status']}")
        print(f"  Data Freshness: {'OK' if freshness.get('is_fresh') else 'STALE'}")
        print(f"  Quality Score: {quality.get('avg_quality_score', 'N/A')}")
        print(f"  Anomaly Count: {anomalies.get('anomaly_count', 'N/A')}")
        print("=" * 60)

        return report

    freshness = check_data_freshness()
    quality = check_data_quality()
    anomalies = check_anomaly_count()
    generate_report(freshness, quality, anomalies)


iot_monitoring()
