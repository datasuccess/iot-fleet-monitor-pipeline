"""
Anomaly Explorer — Streamlit in Snowflake
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


st.set_page_config(page_title="Anomaly Explorer", page_icon="🚨", layout="wide")
st.title("🚨 Anomaly Explorer")

# ──────────────────────────────────────────────
# Filters
# ──────────────────────────────────────────────
col1, col2, col3 = st.columns(3)

with col1:
    severity = st.multiselect(
        "Severity", options=["critical", "warning", "info"],
        default=["critical", "warning"],
    )

with col2:
    sensor = st.multiselect(
        "Sensor Type", options=["temperature", "humidity", "pressure", "battery"],
        default=["temperature", "humidity", "pressure", "battery"],
    )

with col3:
    days_back = st.slider("Days Back", min_value=1, max_value=30, value=7)

severity_str = ", ".join(f"'{s}'" for s in severity)
sensor_str = ", ".join(f"'{s}'" for s in sensor)

if not severity or not sensor:
    st.warning("Select at least one severity and sensor type.")
    st.stop()

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
st.header("Summary")

summary = run_query(f"""
    SELECT severity, sensor_type, anomaly_type, COUNT(*) AS count
    FROM IOT_PIPELINE.MARTS.fct_anomalies
    WHERE detected_at >= DATEADD(day, -{days_back}, CURRENT_TIMESTAMP())
      AND severity IN ({severity_str})
      AND sensor_type IN ({sensor_str})
    GROUP BY 1, 2, 3
    ORDER BY count DESC
""")

if not summary.empty:
    total = int(summary["count"].sum())
    st.metric("Total Anomalies", f"{total:,}")

    col1, col2 = st.columns(2)

    with col1:
        fig = px.bar(
            summary, x="sensor_type", y="count", color="severity",
            title="Anomalies by Sensor Type", barmode="group",
            color_discrete_map={"critical": "#e74c3c", "warning": "#f39c12", "info": "#3498db"},
        )
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        fig = px.pie(
            summary, names="severity", values="count",
            title="Anomalies by Severity", color="severity",
            color_discrete_map={"critical": "#e74c3c", "warning": "#f39c12", "info": "#3498db"},
        )
        st.plotly_chart(fig, use_container_width=True)
else:
    st.info("No anomalies found for the selected filters.")

# ──────────────────────────────────────────────
# Trend
# ──────────────────────────────────────────────
st.header("Anomaly Trend")

trend = run_query(f"""
    SELECT detected_at::date AS date, severity, COUNT(*) AS count
    FROM IOT_PIPELINE.MARTS.fct_anomalies
    WHERE detected_at >= DATEADD(day, -{days_back}, CURRENT_TIMESTAMP())
      AND severity IN ({severity_str})
      AND sensor_type IN ({sensor_str})
    GROUP BY 1, 2
    ORDER BY 1
""")

if not trend.empty:
    fig = px.line(
        trend, x="date", y="count", color="severity",
        title="Anomalies Over Time", markers=True,
        color_discrete_map={"critical": "#e74c3c", "warning": "#f39c12", "info": "#3498db"},
    )
    st.plotly_chart(fig, use_container_width=True)

# ──────────────────────────────────────────────
# Top Devices
# ──────────────────────────────────────────────
st.header("Top Anomaly Devices")

top_devices = run_query(f"""
    SELECT device_id, COUNT(*) AS anomaly_count,
           COUNT(CASE WHEN severity = 'critical' THEN 1 END) AS critical_count,
           COUNT(CASE WHEN severity = 'warning' THEN 1 END) AS warning_count
    FROM IOT_PIPELINE.MARTS.fct_anomalies
    WHERE detected_at >= DATEADD(day, -{days_back}, CURRENT_TIMESTAMP())
      AND severity IN ({severity_str})
      AND sensor_type IN ({sensor_str})
    GROUP BY 1
    ORDER BY anomaly_count DESC
    LIMIT 15
""")

if not top_devices.empty:
    fig = px.bar(
        top_devices, x="device_id", y=["critical_count", "warning_count"],
        title="Top 15 Devices by Anomaly Count", barmode="stack",
        color_discrete_map={"critical_count": "#e74c3c", "warning_count": "#f39c12"},
    )
    fig.update_xaxes(tickangle=45)
    st.plotly_chart(fig, use_container_width=True)

# ──────────────────────────────────────────────
# Device Drill-Down
# ──────────────────────────────────────────────
st.header("Device Drill-Down")

device_list = run_query("""
    SELECT DISTINCT device_id FROM IOT_PIPELINE.MARTS.fct_anomalies ORDER BY device_id
""")

if not device_list.empty:
    selected = st.selectbox("Select Device", device_list["device_id"].tolist())

    device_data = run_query(f"""
        SELECT detected_at, anomaly_type, sensor_type, observed_value,
               expected_min, expected_max, zscore, severity
        FROM IOT_PIPELINE.MARTS.fct_anomalies
        WHERE device_id = '{selected}'
          AND detected_at >= DATEADD(day, -{days_back}, CURRENT_TIMESTAMP())
        ORDER BY detected_at DESC
        LIMIT 100
    """)

    if not device_data.empty:
        st.dataframe(device_data, use_container_width=True, hide_index=True)

        fig = px.scatter(
            device_data, x="detected_at", y="observed_value",
            color="sensor_type", symbol="severity",
            title=f"Anomaly Values — {selected}",
        )
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info(f"No anomalies for {selected}.")
