"""
Pipeline Admin
Trigger Lambda, view pipeline status, run queries, manage error profiles.
"""

import os

import streamlit as st
import pandas as pd
import plotly.express as px
from connection import run_query

st.set_page_config(page_title="Pipeline Admin", page_icon="🔧", layout="wide")
st.title("Pipeline Admin")

# ──────────────────────────────────────────────
# Pipeline Status
# ──────────────────────────────────────────────
st.header("Pipeline Status")

col1, col2 = st.columns(2)

with col1:
    st.subheader("Raw Data Status")
    try:
        raw_status = run_query("""
            SELECT
                COUNT(*) AS total_rows,
                COUNT(DISTINCT source_file) AS total_files,
                MIN(loaded_at) AS first_load,
                MAX(loaded_at) AS latest_load,
                DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) AS minutes_since_last
            FROM IOT_PIPELINE.RAW.sensor_readings
        """)
        if not raw_status.empty:
            r = raw_status.iloc[0]
            st.metric("Total Raw Rows", f"{int(r['total_rows']):,}")
            st.metric("Total Files Loaded", int(r["total_files"]))
            st.metric("First Load", str(r["first_load"])[:19])
            st.metric("Latest Load", str(r["latest_load"])[:19])
            mins = int(r["minutes_since_last"])
            status = "Fresh" if mins < 120 else "STALE"
            st.metric("Minutes Since Last Load", f"{mins} ({status})")
    except Exception as e:
        st.error(f"Error: {e}")

with col2:
    st.subheader("Model Row Counts")
    try:
        counts = run_query("""
            SELECT 'stg_sensor_readings' AS model, COUNT(*) AS row_count FROM IOT_PIPELINE.STAGING.stg_sensor_readings
            UNION ALL SELECT 'int_readings_deduped', COUNT(*) FROM IOT_PIPELINE.INTERMEDIATE.int_readings_deduped
            UNION ALL SELECT 'int_quarantined_readings', COUNT(*) FROM IOT_PIPELINE.INTERMEDIATE.int_quarantined_readings
            UNION ALL SELECT 'int_late_arriving_readings', COUNT(*) FROM IOT_PIPELINE.INTERMEDIATE.int_late_arriving_readings
            UNION ALL SELECT 'fct_hourly_readings', COUNT(*) FROM IOT_PIPELINE.MARTS.fct_hourly_readings
            UNION ALL SELECT 'fct_device_health', COUNT(*) FROM IOT_PIPELINE.MARTS.fct_device_health
            UNION ALL SELECT 'fct_anomalies', COUNT(*) FROM IOT_PIPELINE.MARTS.fct_anomalies
            UNION ALL SELECT 'fct_data_quality', COUNT(*) FROM IOT_PIPELINE.MARTS.fct_data_quality
            UNION ALL SELECT 'dim_devices', COUNT(*) FROM IOT_PIPELINE.MARTS.dim_devices
        """)
        st.dataframe(counts, use_container_width=True, hide_index=True)
    except Exception as e:
        st.error(f"Error: {e}")

# ──────────────────────────────────────────────
# Trigger Lambda
# ──────────────────────────────────────────────
st.header("Trigger Data Generation")

col1, col2 = st.columns(2)

with col1:
    profile = st.selectbox(
        "Error Profile",
        options=["none", "normal", "high", "chaos"],
        index=1,
        help="none=clean, normal=3% errors, high=10% errors, chaos=25% errors",
    )

with col2:
    st.write("")
    st.write("")
    trigger = st.button("Trigger Lambda", type="primary")

if trigger:
    try:
        import json
        import boto3
        from botocore.config import Config

        config = Config(
            retries={"max_attempts": 3, "mode": "adaptive"},
            read_timeout=120,
        )
        client = boto3.client(
            "lambda",
            region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
            config=config,
        )

        with st.spinner("Invoking Lambda..."):
            response = client.invoke(
                FunctionName="iot-fleet-data-generator",
                InvocationType="RequestResponse",
                Payload=json.dumps({"error_profile": profile}),
            )
            payload = json.loads(response["Payload"].read().decode("utf-8"))

            if response.get("FunctionError"):
                st.error(f"Lambda failed: {json.dumps(payload, indent=2)}")
            else:
                st.success("Lambda triggered successfully!")
                st.json(payload)
    except Exception as e:
        st.error(f"Failed to trigger Lambda: {e}")

# ──────────────────────────────────────────────
# Custom Query Runner
# ──────────────────────────────────────────────
st.header("Query Runner")

query = st.text_area(
    "SQL Query",
    value="SELECT * FROM IOT_PIPELINE.MARTS.rpt_fleet_overview ORDER BY report_date DESC LIMIT 10",
    height=120,
)

if st.button("Run Query"):
    try:
        with st.spinner("Running..."):
            result = run_query(query)
        st.success(f"Returned {len(result)} rows")
        st.dataframe(result, use_container_width=True, hide_index=True)
    except Exception as e:
        st.error(f"Query error: {e}")

# ──────────────────────────────────────────────
# Snowflake Warehouse Usage
# ──────────────────────────────────────────────
st.header("Warehouse Activity")

try:
    wh = run_query("""
        SELECT
            query_id,
            query_type,
            execution_status,
            total_elapsed_time / 1000 AS elapsed_seconds,
            rows_produced,
            bytes_scanned / 1024 / 1024 AS mb_scanned,
            start_time
        FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
            DATE_RANGE_START => DATEADD(hour, -6, CURRENT_TIMESTAMP()),
            RESULT_LIMIT => 50
        ))
        ORDER BY start_time DESC
    """)

    if not wh.empty:
        col1, col2 = st.columns(2)
        with col1:
            st.metric("Queries (last 6h)", len(wh))
            st.metric("Avg Elapsed (sec)", f"{wh['elapsed_seconds'].mean():.2f}")
        with col2:
            st.metric("Total MB Scanned", f"{wh['mb_scanned'].sum():.1f}")
            failed = len(wh[wh["execution_status"] != "SUCCESS"])
            st.metric("Failed Queries", failed)

        st.dataframe(wh, use_container_width=True, hide_index=True)
except Exception as e:
    st.info(f"Could not fetch warehouse activity: {e}")
