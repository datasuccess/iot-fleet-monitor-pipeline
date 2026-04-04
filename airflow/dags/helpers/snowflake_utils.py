"""Snowflake query helper using direct connector with key-pair auth."""

import os

import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization


def _load_private_key():
    """Load RSA private key from file for key-pair authentication."""
    key_path = os.environ.get(
        "SNOWFLAKE_PRIVATE_KEY_PATH", "/opt/airflow/keys/rsa_key.p8"
    )
    with open(key_path, "rb") as f:
        private_key = serialization.load_pem_private_key(
            f.read(), password=None, backend=default_backend()
        )
    return private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def get_snowflake_connection():
    """Create a Snowflake connection using key-pair authentication."""
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key=_load_private_key(),
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
