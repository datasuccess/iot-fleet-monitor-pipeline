"""
Fleet Monitor — Main Streamlit App
Real-time fleet health overview with device map, battery levels, and anomaly feed.
"""

import streamlit as st
import plotly.express as px
import plotly.graph_objects as go
from connection import run_query

st.set_page_config(
    page_title="IoT Fleet Monitor",
    page_icon="📡",
    layout="wide",
)

st.title("IoT Fleet Monitor")
st.caption("Real-time fleet health dashboard")

# ──────────────────────────────────────────────
# KPI Row — Fleet Overview
# ──────────────────────────────────────────────
st.header("Fleet Overview")

try:
    kpi = run_query("""
        SELECT *
        FROM IOT_PIPELINE.MARTS.rpt_fleet_overview
        ORDER BY report_date DESC
        LIMIT 1
    """)

    if not kpi.empty:
        row = kpi.iloc[0]
        c1, c2, c3, c4, c5, c6 = st.columns(6)
        c1.metric("Active Devices", int(row["active_devices"]))
        c2.metric("Total Readings", f"{int(row['total_readings']):,}")
        c3.metric("Quality Score", f"{row['avg_quality_score']:.1f}")
        c4.metric("Fleet Uptime", f"{row['fleet_uptime_pct']:.1f}%")
        c5.metric("Critical Alerts", int(row["critical_alerts"]))
        c6.metric("Devices Offline", int(row["devices_offline"]))
    else:
        st.warning("No fleet overview data yet. Wait for the pipeline to run.")
except Exception as e:
    st.error(f"Connection error: {e}")
    st.stop()

# ──────────────────────────────────────────────
# Fleet Overview Trend
# ──────────────────────────────────────────────
st.header("Daily Trends")

trend = run_query("""
    SELECT report_date, active_devices, total_readings,
           avg_quality_score, critical_alerts, warning_alerts,
           fleet_uptime_pct, total_anomalies
    FROM IOT_PIPELINE.MARTS.rpt_fleet_overview
    ORDER BY report_date
""")

if not trend.empty:
    col1, col2 = st.columns(2)

    with col1:
        fig = px.line(
            trend, x="report_date", y="avg_quality_score",
            title="Quality Score Trend",
            markers=True,
        )
        fig.add_hline(y=80, line_dash="dash", line_color="orange", annotation_text="Warn")
        fig.add_hline(y=60, line_dash="dash", line_color="red", annotation_text="Critical")
        fig.update_yaxes(range=[0, 105])
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        fig = px.bar(
            trend, x="report_date", y=["critical_alerts", "warning_alerts"],
            title="Alerts by Day",
            barmode="stack",
            color_discrete_map={"critical_alerts": "#e74c3c", "warning_alerts": "#f39c12"},
        )
        st.plotly_chart(fig, use_container_width=True)

# ──────────────────────────────────────────────
# Device Health Table
# ──────────────────────────────────────────────
st.header("Device Health")

health = run_query("""
    SELECT device_id, report_date, health_status,
           avg_battery_pct, min_battery_pct, uptime_pct,
           readings_received, alert_count
    FROM IOT_PIPELINE.MARTS.fct_device_health
    WHERE report_date = (SELECT MAX(report_date) FROM IOT_PIPELINE.MARTS.fct_device_health)
    ORDER BY
        CASE health_status
            WHEN 'critical' THEN 1
            WHEN 'warning' THEN 2
            ELSE 3
        END,
        device_id
""")

if not health.empty:
    # Health distribution
    col1, col2 = st.columns([1, 2])

    with col1:
        health_counts = health["health_status"].value_counts().reset_index()
        health_counts.columns = ["status", "count"]
        color_map = {"critical": "#e74c3c", "warning": "#f39c12", "healthy": "#2ecc71"}
        fig = px.pie(
            health_counts, names="status", values="count",
            title="Health Distribution",
            color="status",
            color_discrete_map=color_map,
        )
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        # Battery heatmap
        fig = px.bar(
            health.sort_values("avg_battery_pct"),
            x="device_id", y="avg_battery_pct",
            color="health_status",
            color_discrete_map=color_map,
            title="Battery Level by Device",
        )
        fig.add_hline(y=15, line_dash="dash", line_color="red", annotation_text="Low Battery")
        fig.update_xaxes(tickangle=45, tickfont_size=8)
        st.plotly_chart(fig, use_container_width=True)

    # Full table
    st.dataframe(
        health.style.applymap(
            lambda v: "background-color: #ffcccc" if v == "critical"
            else "background-color: #fff3cd" if v == "warning"
            else "",
            subset=["health_status"],
        ),
        use_container_width=True,
        hide_index=True,
    )

# ──────────────────────────────────────────────
# Device Map
# ──────────────────────────────────────────────
st.header("Device Map")

devices = run_query("""
    SELECT d.device_id, d.base_latitude AS lat, d.base_longitude AS lon,
           d.cluster_id, d.device_status,
           h.health_status, h.avg_battery_pct
    FROM IOT_PIPELINE.MARTS.dim_devices d
    LEFT JOIN IOT_PIPELINE.MARTS.fct_device_health h
        ON d.device_id = h.device_id
        AND h.report_date = (SELECT MAX(report_date) FROM IOT_PIPELINE.MARTS.fct_device_health)
""")

if not devices.empty and "lat" in devices.columns:
    color_map_status = {
        "critical": "red", "warning": "orange", "healthy": "green",
    }
    devices["color"] = devices["health_status"].map(color_map_status).fillna("gray")

    fig = px.scatter_mapbox(
        devices,
        lat="lat", lon="lon",
        color="health_status",
        color_discrete_map={"critical": "#e74c3c", "warning": "#f39c12", "healthy": "#2ecc71"},
        hover_name="device_id",
        hover_data=["cluster_id", "avg_battery_pct", "device_status"],
        zoom=3,
        height=500,
        title="Device Locations",
    )
    fig.update_layout(mapbox_style="open-street-map")
    st.plotly_chart(fig, use_container_width=True)

# ──────────────────────────────────────────────
# Recent Anomalies Feed
# ──────────────────────────────────────────────
st.header("Recent Anomalies")

anomalies = run_query("""
    SELECT device_id, detected_at, anomaly_type, sensor_type,
           observed_value, expected_min, expected_max, severity
    FROM IOT_PIPELINE.MARTS.fct_anomalies
    ORDER BY detected_at DESC
    LIMIT 50
""")

if not anomalies.empty:
    severity_filter = st.multiselect(
        "Filter by severity",
        options=["critical", "warning", "info"],
        default=["critical", "warning"],
    )
    filtered = anomalies[anomalies["severity"].isin(severity_filter)]
    st.dataframe(filtered, use_container_width=True, hide_index=True)
else:
    st.info("No anomalies detected yet.")
