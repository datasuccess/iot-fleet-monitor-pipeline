"""Snowflake query helper using direct connector."""

import os

import snowflake.connector


def get_snowflake_connection():
    """Create a Snowflake connection from environment variables."""
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ.get("SNOWFLAKE_ROLE", "IOT_TRANSFORMER"),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "IOT_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "IOT_PIPELINE"),
    )


def run_snowflake_query(sql: str, params: dict = None) -> list:
    """Execute a Snowflake query and return results.

    Args:
        sql: SQL statement to execute
        params: Optional bind parameters

    Returns:
        List of result rows (each row is a tuple)
    """
    conn = get_snowflake_connection()
    try:
        cursor = conn.cursor()
        cursor.execute(sql, params)
        results = cursor.fetchall()
        cursor.close()
        return results
    finally:
        conn.close()
