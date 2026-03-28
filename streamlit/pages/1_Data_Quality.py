"""
Data Quality Dashboard
Quality score trends, quarantine breakdown, freshness status.
"""

import streamlit as st
import plotly.express as px
import plotly.graph_objects as go
from connection import run_query

st.set_page_config(page_title="Data Quality", page_icon="🔍", layout="wide")
st.title("Data Quality Dashboard")

# ──────────────────────────────────────────────
# Freshness Check
# ──────────────────────────────────────────────
st.header("Data Freshness")

freshness = run_query("""
    SELECT
        MAX(loaded_at) AS latest_load,
        DATEDIFF(minute, MAX(loaded_at), CURRENT_TIMESTAMP()) AS minutes_ago
    FROM IOT_PIPELINE.RAW.sensor_readings
""")

if not freshness.empty:
    mins = int(freshness.iloc[0]["minutes_ago"])
    latest = freshness.iloc[0]["latest_load"]

    col1, col2 = st.columns(2)
    col1.metric("Last Data Load", str(latest)[:19])

    if mins <= 60:
        col2.metric("Minutes Ago", mins, delta="Fresh", delta_color="normal")
    elif mins <= 120:
        col2.metric("Minutes Ago", mins, delta="Stale", delta_color="inverse")
    else:
        col2.metric("Minutes Ago", mins, delta="CRITICAL", delta_color="inverse")

# ──────────────────────────────────────────────
# Quality Score Trend
# ──────────────────────────────────────────────
st.header("Quality Score Trend")

quality = run_query("""
    SELECT
        batch_ts,
        source_file,
        total_records,
        null_count,
        null_pct,
        duplicate_count,
        duplicate_pct,
        quarantined_count,
        late_arrival_count,
        quality_score
    FROM IOT_PIPELINE.MARTS.fct_data_quality
    ORDER BY batch_ts DESC
    LIMIT 100
""")

if not quality.empty:
    # Score trend line
    fig = px.line(
        quality.sort_values("batch_ts"),
        x="batch_ts", y="quality_score",
        title="Quality Score Over Time",
        markers=True,
    )
    fig.add_hline(y=80, line_dash="dash", line_color="orange", annotation_text="Warn (80)")
    fig.add_hline(y=60, line_dash="dash", line_color="red", annotation_text="Critical (60)")
    fig.update_yaxes(range=[0, 105])
    st.plotly_chart(fig, use_container_width=True)

    # Summary metrics
    col1, col2, col3, col4 = st.columns(4)
    col1.metric("Avg Quality Score", f"{quality['quality_score'].mean():.1f}")
    col2.metric("Total Nulls", f"{int(quality['null_count'].sum()):,}")
    col3.metric("Total Duplicates", f"{int(quality['duplicate_count'].sum()):,}")
    col4.metric("Total Quarantined", f"{int(quality['quarantined_count'].sum()):,}")

    # Quality breakdown stacked area
    col1, col2 = st.columns(2)

    with col1:
        fig = px.bar(
            quality.sort_values("batch_ts"),
            x="batch_ts",
            y=["null_pct", "duplicate_pct"],
            title="Null % vs Duplicate % per Batch",
            barmode="group",
        )
        st.plotly_chart(fig, use_container_width=True)

    with col2:
        fig = px.bar(
            quality.sort_values("batch_ts"),
            x="batch_ts",
            y=["quarantined_count", "late_arrival_count"],
            title="Quarantined & Late Arrivals per Batch",
            barmode="group",
            color_discrete_sequence=["#e74c3c", "#3498db"],
        )
        st.plotly_chart(fig, use_container_width=True)

    # Full table
    st.subheader("Batch Details")
    st.dataframe(quality, use_container_width=True, hide_index=True)
else:
    st.warning("No quality data yet.")

# ──────────────────────────────────────────────
# Quarantine Analysis
# ──────────────────────────────────────────────
st.header("Quarantine Analysis")

quarantine = run_query("""
    SELECT
        device_id,
        reading_ts,
        temperature,
        humidity,
        pressure,
        battery_pct,
        rejection_reasons,
        loaded_at
    FROM IOT_PIPELINE.INTERMEDIATE.int_quarantined_readings
    ORDER BY loaded_at DESC
    LIMIT 200
""")

if not quarantine.empty:
    st.metric("Quarantined Records (last 200)", len(quarantine))
    st.dataframe(quarantine, use_container_width=True, hide_index=True)
else:
    st.info("No quarantined records yet.")

# ──────────────────────────────────────────────
# Late Arrivals
# ──────────────────────────────────────────────
st.header("Late Arrivals")

late = run_query("""
    SELECT
        device_id,
        reading_ts,
        loaded_at,
        arrival_delay_minutes
    FROM IOT_PIPELINE.INTERMEDIATE.int_late_arriving_readings
    ORDER BY loaded_at DESC
    LIMIT 100
""")

if not late.empty:
    col1, col2 = st.columns(2)
    col1.metric("Late Records (last 100)", len(late))
    col2.metric("Avg Delay (min)", f"{late['arrival_delay_minutes'].mean():.1f}")

    fig = px.histogram(
        late, x="arrival_delay_minutes",
        title="Arrival Delay Distribution (minutes)",
        nbins=30,
    )
    st.plotly_chart(fig, use_container_width=True)
else:
    st.info("No late arrivals detected.")
