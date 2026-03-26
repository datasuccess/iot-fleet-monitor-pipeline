#!/bin/bash
# =============================================================================
# Create IAM Role for Snowflake → S3 Access
# Run from your local machine: bash infrastructure/setup-snowflake-iam.sh
# =============================================================================

set -euo pipefail

echo "============================================"
echo "  Setting up Snowflake IAM Trust"
echo "============================================"
echo ""

# --- Step 1: Create IAM role with Snowflake trust policy ---
echo "[1/2] Creating IAM role: iot-fleet-snowflake-role..."

aws iam create-role \
  --role-name iot-fleet-snowflake-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::115005006440:user/o0dh1000-s"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "MM75901_SFCRole=4_LqGFi1Fg01yn/gZPrWLvh2HhwEo="
        }
      }
    }]
  }'

echo "       Role created"

# --- Step 2: Attach S3 access policy ---
echo "[2/2] Attaching S3 access policy..."

aws iam put-role-policy \
  --role-name iot-fleet-snowflake-role \
  --policy-name s3-access \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::iot-fleet-monitor-data",
        "arn:aws:s3:::iot-fleet-monitor-data/*"
      ]
    }]
  }'

echo "       Policy attached"
echo ""
echo "============================================"
echo "  Done! Test in Snowflake:"
echo "  LIST @RAW.raw_sensor_stage;"
echo "============================================"
