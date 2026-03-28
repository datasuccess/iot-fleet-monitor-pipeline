"""Snowflake connection helper for Streamlit apps."""

import os

import pandas as pd
import snowflake.connector
from dotenv import load_dotenv

# Load .env from airflow folder
load_dotenv(os.path.join(os.path.dirname(__file__), "..", "airflow", ".env"))


def get_connection():
    """Create a Snowflake connection from environment variables."""
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ.get("SNOWFLAKE_ROLE", "IOT_TRANSFORMER"),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "IOT_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "IOT_PIPELINE"),
    )


def run_query(sql: str) -> pd.DataFrame:
    """Execute a query and return results as a DataFrame."""
    conn = get_connection()
    try:
        df = pd.read_sql(sql, conn)
        # Lowercase column names for consistency
        df.columns = [c.lower() for c in df.columns]
        return df
    finally:
        conn.close()
