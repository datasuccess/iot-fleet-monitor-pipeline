# Infrastructure Setup — EC2 + Docker Compose

## Instance Specification

| Setting | Value |
|---------|-------|
| Instance type | `t4g.small` (ARM/Graviton) |
| vCPU | 2 |
| RAM | 2 GB (+2 GB swap) |
| Storage | 30 GB gp3 EBS |
| AMI | Ubuntu 24.04 LTS ARM64 |
| Cost | ~$0.0168/hr = ~$12/month |

## Step-by-Step Launch

### 1. Launch EC2 Instance

**AWS Console → EC2 → Launch Instance**:

- **Name**: `iot-fleet-pipeline`
- **AMI**: Ubuntu 24.04 LTS — select **64-bit (Arm)**
- **Instance type**: `t4g.small`
- **Key pair**: Create new or select existing (you'll need this to SSH)
- **Network settings**:
  - Allow SSH (port 22) — **your IP only**
  - Add rule: Custom TCP, port **8080**, source **your IP only** (Airflow UI)
- **Storage**: 30 GB, gp3
- **Advanced details → User data**: Paste contents of `ec2-setup.sh`
  *(or run it manually after SSH-ing in)*

Click **Launch Instance**.

### 2. SSH into the Instance

```bash
# Wait ~2 minutes for instance to start
ssh -i your-key.pem ubuntu@<EC2-PUBLIC-IP>
```

### 3. Run Setup (if you didn't use User Data)

```bash
sudo bash /path/to/ec2-setup.sh

# Log out and back in for docker group to take effect
exit
ssh -i your-key.pem ubuntu@<EC2-PUBLIC-IP>
```

### 4. Clone and Start Airflow

```bash
cd /home/ubuntu/iot-pipeline
git clone https://github.com/datasuccess/iot-fleet-monitor-pipeline.git .
cd airflow

# Set Airflow user ID
echo -e "AIRFLOW_UID=$(id -u)" > .env

# Start Airflow
docker compose up -d

# Check status
docker compose ps

# View logs (first startup takes a few minutes)
docker compose logs -f airflow-webserver
```

### 5. Access Airflow UI

Open in browser: `http://<EC2-PUBLIC-IP>:8080`

Default credentials (change in production):
- Username: `airflow`
- Password: `airflow`

## Cost Management

### Stop when not using (saves money)

```bash
# From your local machine
aws ec2 stop-instances --instance-ids <INSTANCE-ID>

# Resume later
aws ec2 start-instances --instance-ids <INSTANCE-ID>
```

**Note**: Public IP changes on restart unless you attach an **Elastic IP** (free while attached to a running instance).

### Attach Elastic IP (optional, recommended)

1. EC2 Console → Elastic IPs → Allocate
2. Actions → Associate → Select your instance

This gives you a fixed IP that survives instance stop/start.

## Security Checklist

- [ ] SSH restricted to your IP only (not 0.0.0.0/0)
- [ ] Port 8080 restricted to your IP only
- [ ] Key pair stored securely, not in repo
- [ ] Change default Airflow admin password
- [ ] No secrets in docker-compose.yml (use .env or AWS Secrets Manager)

## Troubleshooting

**Airflow webserver won't start / OOM**:
```bash
# Check memory
free -h

# Verify swap is active (should show 2GB)
swapon --show

# Check Docker container logs
docker compose logs airflow-webserver
```

**Can't connect to port 8080**:
1. Check security group allows your IP on port 8080
2. Check Airflow is running: `docker compose ps`
3. Check the container is healthy: `docker compose logs airflow-webserver`

**Docker permission denied**:
```bash
# Make sure you logged out and back in after setup
groups  # should show 'docker'
```
