"""Lambda invocation helper with retry logic."""

import json
import os

import boto3
from botocore.config import Config


def invoke_lambda(
    function_name: str,
    payload: dict,
    region: str = None,
) -> dict:
    """Invoke an AWS Lambda function and return the parsed response.

    Args:
        function_name: Lambda function name
        payload: Event payload dict
        region: AWS region (defaults to AWS_DEFAULT_REGION env var)

    Returns:
        Parsed response body from Lambda
    """
    region = region or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

    config = Config(
        retries={"max_attempts": 3, "mode": "adaptive"},
        read_timeout=120,
    )

    client = boto3.client("lambda", region_name=region, config=config)

    response = client.invoke(
        FunctionName=function_name,
        InvocationType="RequestResponse",
        Payload=json.dumps(payload),
    )

    response_payload = json.loads(response["Payload"].read().decode("utf-8"))

    # Check for Lambda errors
    if response.get("FunctionError"):
        raise RuntimeError(
            f"Lambda {function_name} failed: {json.dumps(response_payload)}"
        )

    status_code = response_payload.get("statusCode", 200)
    if status_code != 200:
        raise RuntimeError(
            f"Lambda returned status {status_code}: {response_payload.get('body')}"
        )

    return response_payload
