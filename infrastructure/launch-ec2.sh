#!/bin/bash
# =============================================================================
# Launch EC2 Instance — IoT Fleet Monitor Pipeline
# Run from your local machine: bash infrastructure/launch-ec2.sh
# Requires: AWS CLI configured with credentials
# =============================================================================

set -euo pipefail

# --- Configuration ---
PROJECT_NAME="iot-fleet-pipeline"
INSTANCE_TYPE="t4g.small"
REGION="us-east-1"
KEY_NAME="${PROJECT_NAME}-key"
SG_NAME="${PROJECT_NAME}-sg"
VOLUME_SIZE=30

echo "============================================"
echo "  Launching EC2 for IoT Fleet Pipeline"
echo "  Instance: ${INSTANCE_TYPE} (ARM/Graviton)"
echo "  Region:   ${REGION}"
echo "============================================"
echo ""

# --- Get your public IP for security group ---
echo "[1/7] Detecting your public IP..."
MY_IP=$(curl -s https://checkip.amazonaws.com)
echo "       Your IP: ${MY_IP}"

# --- Find latest Ubuntu 24.04 ARM64 AMI ---
echo "[2/7] Finding Ubuntu 24.04 ARM64 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --region "${REGION}" \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
        "Name=state,Values=available" \
    --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
    --output text)
echo "       AMI: ${AMI_ID}"

# --- Create key pair (skip if exists) ---
echo "[3/7] Setting up key pair..."
KEY_FILE="${HOME}/.ssh/${KEY_NAME}.pem"
if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${REGION}" &>/dev/null; then
    echo "       Key pair '${KEY_NAME}' already exists"
    if [ ! -f "${KEY_FILE}" ]; then
        echo "       WARNING: Key file not found at ${KEY_FILE}"
        echo "       You may need to delete the key pair and re-run:"
        echo "         aws ec2 delete-key-pair --key-name ${KEY_NAME}"
        exit 1
    fi
else
    aws ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --region "${REGION}" \
        --query 'KeyMaterial' \
        --output text > "${KEY_FILE}"
    chmod 400 "${KEY_FILE}"
    echo "       Created: ${KEY_FILE}"
fi

# --- Create security group (skip if exists) ---
echo "[4/7] Setting up security group..."
SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --region "${REGION}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [ "${SG_ID}" = "None" ] || [ -z "${SG_ID}" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${SG_NAME}" \
        --description "IoT Fleet Pipeline - SSH and Airflow UI" \
        --region "${REGION}" \
        --query 'GroupId' \
        --output text)

    # SSH access — your IP only
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 22 \
        --cidr "${MY_IP}/32" \
        --region "${REGION}"

    # Airflow UI — your IP only
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 8080 \
        --cidr "${MY_IP}/32" \
        --region "${REGION}"

    echo "       Created: ${SG_ID} (SSH + 8080 from ${MY_IP})"
else
    echo "       Exists: ${SG_ID}"
fi

# --- Launch instance ---
echo "[5/7] Launching instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --key-name "${KEY_NAME}" \
    --security-group-ids "${SG_ID}" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${VOLUME_SIZE},VolumeType=gp3}" \
    --user-data file://infrastructure/ec2-setup.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}}]" \
    --region "${REGION}" \
    --query 'Instances[0].InstanceId' \
    --output text)
echo "       Instance: ${INSTANCE_ID}"

# --- Wait for instance to be running ---
echo "[6/7] Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${REGION}"
echo "       Instance is running"

# --- Get public IP ---
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${REGION}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

# --- Save instance info ---
echo "[7/7] Saving instance info..."
cat > infrastructure/.instance-info <<EOF
INSTANCE_ID=${INSTANCE_ID}
PUBLIC_IP=${PUBLIC_IP}
KEY_FILE=${KEY_FILE}
REGION=${REGION}
SG_ID=${SG_ID}
EOF

echo ""
echo "============================================"
echo "  EC2 Instance Launched!"
echo "============================================"
echo ""
echo "  Instance ID:  ${INSTANCE_ID}"
echo "  Public IP:    ${PUBLIC_IP}"
echo "  Key file:     ${KEY_FILE}"
echo ""
echo "  The bootstrap script is installing Docker."
echo "  Wait ~3 minutes, then:"
echo ""
echo "  1. SSH in:"
echo "     ssh -i ${KEY_FILE} ubuntu@${PUBLIC_IP}"
echo ""
echo "  2. Clone repo and start Airflow:"
echo "     cd /home/ubuntu/iot-pipeline"
echo "     git clone https://github.com/datasuccess/iot-fleet-monitor-pipeline.git ."
echo "     cd airflow"
echo "     echo \"AIRFLOW_UID=\$(id -u)\" > .env"
echo "     docker compose up -d"
echo ""
echo "  3. Airflow UI (wait ~2 min after compose up):"
echo "     http://${PUBLIC_IP}:8080"
echo "     Login: airflow / airflow"
echo ""
echo "  To stop (saves money):"
echo "     aws ec2 stop-instances --instance-ids ${INSTANCE_ID}"
echo ""
echo "  To terminate (delete everything):"
echo "     aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}"
echo ""
