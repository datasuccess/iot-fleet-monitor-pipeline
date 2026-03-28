"""
Pipeline Admin — Streamlit in Snowflake
Row counts, query runner, warehouse activity.
Note: Lambda triggering not available from inside Snowflake (no AWS access).
"""

import streamlit as st
import pandas as pd
import plotly.express as px
from snowflake.snowpark.context import get_active_session

session = get_active_session()


def run_query(sql: str) -> pd.DataFrame:
    df = session.sql(sql).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    return df


st.set_page_config(page_title="Pipeline Admin", page_icon="🔧", layout="wide")
st.title("🔧 Pipeline Admin")

# ──────────────────────────────────────────────
# Pipeline Status
# ──────────────────────────────────────────────
st.header("Pipeline Status")

col1, col2 = st.columns(2)

with col1:
    st.subheader("Raw Data Status")
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

with col2:
    st.subheader("Model Row Counts")
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

    # Row count chart
    fig = px.bar(counts, x="model", y="row_count", title="Row Counts by Model")
    fig.update_xaxes(tickangle=45, tickfont_size=9)
    st.plotly_chart(fig, use_container_width=True)

# ──────────────────────────────────────────────
# Query Runner
# ──────────────────────────────────────────────
st.header("Query Runner")

query = st.text_area(
    "SQL Query",
    value="SELECT * FROM IOT_PIPELINE.MARTS.rpt_fleet_overview ORDER BY report_date DESC LIMIT 10",
    height=120,
)

if st.button("Run Query"):
    try:
        result = run_query(query)
        st.success(f"Returned {len(result)} rows")
        st.dataframe(result, use_container_width=True, hide_index=True)
    except Exception as e:
        st.error(f"Query error: {e}")

# ──────────────────────────────────────────────
# Data Lineage Overview
# ──────────────────────────────────────────────
st.header("Data Lineage")

st.markdown("""
```
RAW.sensor_readings (VARIANT JSON)
  → STAGING.stg_sensor_readings (parsed, typed)
    → INTERMEDIATE.int_readings_deduped (duplicates removed)
      → INTERMEDIATE.int_readings_validated (range + z-score checks)
        → INTERMEDIATE.int_readings_enriched (+ device metadata, time dims)
          → MARTS.fct_hourly_readings (hourly aggregations)
          → MARTS.fct_device_health (daily device health)
          → MARTS.fct_anomalies (anomaly event log)
        → INTERMEDIATE.int_quarantined_readings (bad data + reasons)
        → INTERMEDIATE.int_late_arriving_readings (late data)
      → MARTS.fct_data_quality (quality scorecard per batch)
    → MARTS.dim_devices (device dimension)
  → MARTS.rpt_fleet_overview (executive daily summary)
```
""")
