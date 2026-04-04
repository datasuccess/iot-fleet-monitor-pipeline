# Infrastructure — EC2, Docker, Connections & Commands

## EC2 Instance

| Setting | Value |
|---------|-------|
| Instance type | `t4g.small` (ARM/Graviton) |
| vCPU / RAM | 2 / 2 GB (+2 GB swap) |
| Storage | 30 GB gp3 EBS |
| AMI | Ubuntu 24.04 LTS ARM64 |
| Cost | ~$0.0168/hr = ~$12/month |
| Instance ID | i-01182aa00d50da692 |

### Launch Steps

1. **EC2 Console → Launch Instance**: Ubuntu 24.04 ARM64, t4g.small, 30GB gp3
2. **Security group**: SSH (22) + port 8080 — **your IP only**
3. **SSH in**: `ssh -i your-key.pem ubuntu@<IP>`
4. **Run setup**: `sudo bash ec2-setup.sh` → logout/login for docker group
5. **Clone & start**:
   ```bash
   cd /home/ubuntu/iot-pipeline
   git clone https://github.com/datasuccess/iot-fleet-monitor-pipeline.git .
   cd airflow && docker compose up -d
   ```
6. **Access UI**: `http://<IP>:8080` — `airflow` / `airflow`

### Cost Management

```bash
aws ec2 stop-instances --instance-ids i-01182aa00d50da692   # Stop (~$0)
aws ec2 start-instances --instance-ids i-01182aa00d50da692  # Resume
aws ec2 describe-instances --instance-ids i-01182aa00d50da692 \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

Public IP changes on restart unless you attach an **Elastic IP** (free while attached).

---

## Connections & Credentials

### Airflow
- **URL**: `http://<EC2-IP>:8080`
- **Login**: `airflow` / `airflow`

### EC2
```bash
# Get public IP
aws ec2 describe-instances --instance-ids i-01182aa00d50da692 \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text

# SSH
ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@<IP>
```

### S3
- **Bucket**: `iot-fleet-monitor-data`
- **Raw path**: `s3://iot-fleet-monitor-data/sensor_readings/year=YYYY/month=MM/day=DD/hour=HH/`
- **Iceberg**: `s3://iot-fleet-monitor-data/iceberg/iot_pipeline/`

### Snowflake
- **Account**: swtivtz-cj19299 | **Locator**: MM75901
- **Region**: AWS_EU_CENTRAL_1
- **Database**: IOT_PIPELINE | **Warehouse**: IOT_WH
- **User**: DRONQO39
- **Roles**: IOT_LOADER, IOT_TRANSFORMER, IOT_READER

### Lambda
- **Function**: `iot-fleet-data-generator` | **Region**: us-east-1 | **Runtime**: Python 3.11 (ARM64)

### dbt
- **Profile/Project**: `iot_pipeline` | **Packages**: dbt_utils, dbt_expectations

---

## Quick Reference Commands

### EC2 Connection
```bash
# One-shot SSH
ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@$(aws ec2 describe-instances \
  --instance-ids i-01182aa00d50da692 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Get public IP from inside EC2
curl checkip.amazonaws.com
```

### Docker — Status & Logs
```bash
docker compose ps                              # Container status
docker compose logs -f airflow-scheduler       # Follow scheduler logs
docker compose logs --tail 50 airflow-webserver # Last 50 lines
docker stats                                   # CPU/memory usage
```

### Docker — Manage Containers
```bash
docker compose down                 # Stop
docker compose down -v              # Stop + delete database (clean slate)
docker compose up -d                # Start
docker compose restart airflow-webserver  # Restart one service

# Rebuild after changes
docker compose down && docker compose build && docker compose up -d
```

### Docker — Shell Access
```bash
docker exec -it airflow-airflow-webserver-1 bash
docker exec -it airflow-airflow-webserver-1 airflow version
docker exec -it airflow-airflow-webserver-1 airflow dags list
```

### PostgreSQL (Airflow metadata)
```bash
docker exec -it airflow-postgres-1 psql -U airflow -d airflow
```
```sql
\dt                                              -- List tables
SELECT * FROM dag_run ORDER BY start_date DESC LIMIT 10;
SELECT * FROM task_instance ORDER BY start_date DESC LIMIT 10;
\q                                               -- Quit
```

---

## Security Checklist

- [ ] SSH restricted to your IP only (not 0.0.0.0/0)
- [ ] Port 8080 restricted to your IP only
- [ ] Key pair stored securely, not in repo
- [ ] Change default Airflow admin password
- [ ] No secrets in docker-compose.yml (use .env or AWS Secrets Manager)

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Airflow OOM | Check `free -h`, verify swap active (`swapon --show`) |
| Can't reach 8080 | Security group allows your IP? Airflow running? |
| Docker permission denied | Logout/login after setup (check `groups` includes docker) |
