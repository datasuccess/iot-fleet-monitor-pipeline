"""
Custom Airflow sensor that checks for a minimum number of files in an S3 prefix.
"""

import logging

import boto3
from airflow.sensors.base import BaseSensorOperator
from airflow.utils.decorators import apply_defaults

logger = logging.getLogger(__name__)


class S3FileCountSensor(BaseSensorOperator):
    """
    Sensor that waits until a minimum number of files exist under an S3 prefix.

    Uses boto3 directly with environment variable authentication.

    :param bucket_name: S3 bucket name
    :param prefix: S3 key prefix to list objects under
    :param min_count: Minimum number of objects required (default: 1)
    :param aws_conn_id: Not used (kept for interface compatibility); auth via env vars
    """

    template_fields = ("bucket_name", "prefix")

    @apply_defaults
    def __init__(
        self,
        bucket_name: str,
        prefix: str,
        min_count: int = 1,
        aws_conn_id: str = "aws_default",
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.bucket_name = bucket_name
        self.prefix = prefix
        self.min_count = min_count
        self.aws_conn_id = aws_conn_id

    def poke(self, context) -> bool:
        """Check if the number of objects in S3 meets the minimum count."""
        logger.info(
            "Checking s3://%s/%s for at least %d file(s)",
            self.bucket_name,
            self.prefix,
            self.min_count,
        )

        s3_client = boto3.client("s3")
        paginator = s3_client.get_paginator("list_objects_v2")

        file_count = 0
        for page in paginator.paginate(Bucket=self.bucket_name, Prefix=self.prefix):
            contents = page.get("Contents", [])
            file_count += len(contents)
            if file_count >= self.min_count:
                logger.info(
                    "Found %d file(s) (>= %d). Condition met.",
                    file_count,
                    self.min_count,
                )
                return True

        logger.info(
            "Found %d file(s), need at least %d. Will retry.",
            file_count,
            self.min_count,
        )
        return False
