#!/bin/bash
# =============================================================================
# EC2 Bootstrap Script — IoT Fleet Monitor Pipeline
# Instance: t4g.small (ARM/Graviton, 2 vCPU, 2GB RAM)
# OS: Ubuntu 24.04 LTS ARM64
# Run as: sudo bash ec2-setup.sh
# =============================================================================

set -euo pipefail

echo "============================================"
echo "  IoT Fleet Monitor Pipeline — EC2 Setup"
echo "============================================"

# --- System updates ---
echo "[1/6] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# --- Install Docker ---
echo "[2/6] Installing Docker..."
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- Add ubuntu user to docker group ---
echo "[3/6] Configuring Docker permissions..."
usermod -aG docker ubuntu

# --- Configure swap (important for 2GB instance) ---
echo "[4/6] Adding 2GB swap file..."
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- Install git and clone repo ---
echo "[5/6] Installing git..."
apt-get install -y git

# --- Create project directory ---
echo "[6/6] Setting up project directory..."
mkdir -p /home/ubuntu/iot-pipeline
chown ubuntu:ubuntu /home/ubuntu/iot-pipeline

echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "Next steps (as ubuntu user):"
echo "  1. Log out and back in (for docker group)"
echo "  2. cd /home/ubuntu/iot-pipeline"
echo "  3. git clone https://github.com/datasuccess/iot-fleet-monitor-pipeline.git ."
echo "  4. cd airflow"
echo "  5. echo -e \"AIRFLOW_UID=\$(id -u)\" > .env"
echo "  6. docker compose up -d"
echo "  7. Access Airflow UI at http://<EC2-PUBLIC-IP>:8080"
echo ""
