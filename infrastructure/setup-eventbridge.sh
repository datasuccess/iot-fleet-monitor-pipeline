#!/bin/bash
# =============================================================================
# Setup EventBridge rule to trigger Lambda every hour independently
# Lambda runs on its own — no dependency on Airflow
# =============================================================================

set -euo pipefail

FUNCTION_NAME="iot-fleet-data-generator"
RULE_NAME="iot-fleet-hourly-generate"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

echo "Creating EventBridge rule: $RULE_NAME"

# Create the rule — runs at :00 every hour
aws events put-rule \
    --name "$RULE_NAME" \
    --schedule-expression "rate(1 hour)" \
    --state ENABLED \
    --description "Trigger IoT data generator Lambda every hour (independent of Airflow)" \
    --region "$REGION"

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function \
    --function-name "$FUNCTION_NAME" \
    --query 'Configuration.FunctionArn' \
    --output text \
    --region "$REGION")

echo "Lambda ARN: $LAMBDA_ARN"

# Allow EventBridge to invoke Lambda
aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "eventbridge-hourly-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "arn:aws:events:${REGION}:$(aws sts get-caller-identity --query Account --output text):rule/${RULE_NAME}" \
    --region "$REGION" 2>/dev/null || echo "Permission already exists"

# Add Lambda as target — default error profile is "normal"
aws events put-targets \
    --rule "$RULE_NAME" \
    --targets "[{
        \"Id\": \"lambda-target\",
        \"Arn\": \"$LAMBDA_ARN\",
        \"Input\": \"{\\\"error_profile\\\": \\\"normal\\\"}\"
    }]" \
    --region "$REGION"

echo ""
echo "Done! Lambda will now run every hour independently."
echo ""
echo "To change error profile:"
echo "  aws events put-targets --rule $RULE_NAME --targets '[{\"Id\": \"lambda-target\", \"Arn\": \"$LAMBDA_ARN\", \"Input\": \"{\\\\\"error_profile\\\\\": \\\\\"high\\\\\"}\"}]'"
echo ""
echo "To disable:"
echo "  aws events disable-rule --name $RULE_NAME"
echo ""
echo "To check status:"
echo "  aws events describe-rule --name $RULE_NAME"
