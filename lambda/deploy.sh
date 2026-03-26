#!/bin/bash
# =============================================================================
# Deploy Lambda Data Generator to AWS
# Usage: bash lambda/deploy.sh
# =============================================================================

set -euo pipefail

REGION="us-east-1"
FUNCTION_NAME="iot-fleet-data-generator"
S3_BUCKET="iot-fleet-monitor-data"
ROLE_NAME="iot-fleet-lambda-role"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "============================================"
echo "  Deploying IoT Fleet Data Generator"
echo "============================================"
echo ""

# --- Create S3 bucket ---
echo "[1/5] Creating S3 bucket: ${S3_BUCKET}..."
if aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
    echo "       Bucket already exists"
else
    aws s3api create-bucket \
        --bucket "${S3_BUCKET}" \
        --region "${REGION}"
    echo "       Created"
fi

# --- Create IAM role ---
echo "[2/5] Creating IAM role: ${ROLE_NAME}..."
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
    echo "       Role already exists"
else
    aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --region "${REGION}"

    # Attach basic Lambda execution policy
    aws iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

    # Inline policy for S3 write access
    S3_POLICY="{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:PutObject\", \"s3:GetObject\", \"s3:ListBucket\"],
        \"Resource\": [
          \"arn:aws:s3:::${S3_BUCKET}\",
          \"arn:aws:s3:::${S3_BUCKET}/*\"
        ]
      }]
    }"

    aws iam put-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-name "s3-write-access" \
        --policy-document "${S3_POLICY}"

    echo "       Created (waiting 10s for propagation...)"
    sleep 10
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# --- Package Lambda ---
echo "[3/5] Packaging Lambda function..."
cd lambda
rm -rf package lambda-deploy.zip

# Install dependencies
pip3 install -r requirements.txt --target package --quiet \
    --platform manylinux2014_aarch64 --only-binary=:all:
cp -r data_generator package/

# Create zip
cd package
zip -r ../lambda-deploy.zip . -q
cd ..
echo "       Packaged: lambda-deploy.zip"

# --- Create or update Lambda ---
echo "[4/5] Deploying Lambda function: ${FUNCTION_NAME}..."
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${REGION}" &>/dev/null; then
    aws lambda update-function-code \
        --function-name "${FUNCTION_NAME}" \
        --zip-file fileb://lambda-deploy.zip \
        --region "${REGION}" \
        --query 'FunctionArn' \
        --output text
    echo "       Updated"
else
    aws lambda create-function \
        --function-name "${FUNCTION_NAME}" \
        --runtime python3.11 \
        --handler data_generator.handler.lambda_handler \
        --role "${ROLE_ARN}" \
        --zip-file fileb://lambda-deploy.zip \
        --timeout 60 \
        --memory-size 256 \
        --environment "Variables={S3_BUCKET=${S3_BUCKET}}" \
        --architectures arm64 \
        --region "${REGION}" \
        --query 'FunctionArn' \
        --output text
    echo "       Created"
fi

# --- Clean up ---
echo "[5/5] Cleaning up..."
rm -rf package lambda-deploy.zip
cd ..

echo ""
echo "============================================"
echo "  Deployment complete!"
echo "============================================"
echo ""
echo "  Function: ${FUNCTION_NAME}"
echo "  S3 Bucket: ${S3_BUCKET}"
echo "  Role: ${ROLE_NAME}"
echo ""
echo "  Test invoke:"
echo "    aws lambda invoke --function-name ${FUNCTION_NAME} \\"
echo "      --payload '{\"error_profile\": \"none\"}' \\"
echo "      --region ${REGION} \\"
echo "      --cli-binary-format raw-in-base64-out \\"
echo "      /tmp/lambda-response.json && cat /tmp/lambda-response.json"
echo ""
echo "  Check S3:"
echo "    aws s3 ls s3://${S3_BUCKET}/sensor_readings/ --recursive"
echo ""
