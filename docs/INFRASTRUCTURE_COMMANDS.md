# Useful Commands

## EC2 Connection

```bash
# Get public IP
aws ec2 describe-instances --instance-ids i-01182aa00d50da692 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

# SSH into EC2
ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@<PUBLIC-IP>

# Or get IP + SSH in one shot
ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@$(aws ec2 describe-instances \
  --instance-ids i-01182aa00d50da692 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
```

## EC2 Instance Management

```bash
# Stop (saves money, ~$0 when stopped)
aws ec2 stop-instances --instance-ids i-01182aa00d50da692

# Start
aws ec2 start-instances --instance-ids i-01182aa00d50da692

# Check status
aws ec2 describe-instances --instance-ids i-01182aa00d50da692 \
  --query 'Reservations[0].Instances[0].State.Name' --output text

# Terminate (deletes everything permanently)
aws ec2 terminate-instances --instance-ids i-01182aa00d50da692
```

## Docker — Status & Logs

```bash
# Container status (health, uptime, ports)
docker compose ps

# Logs — all services
docker compose logs

# Logs — specific service (follow mode)
docker compose logs -f airflow-webserver
docker compose logs -f airflow-scheduler
docker compose logs -f airflow-init
docker compose logs -f postgres

# Tail last 50 lines
docker compose logs --tail 50 airflow-webserver

# Resource usage (CPU, memory) — Ctrl+C to exit
docker stats
```

## Docker — Manage Containers

```bash
# Stop everything
docker compose down

# Stop and delete database volume (clean slate)
docker compose down -v

# Start everything
docker compose up -d

# Restart one service
docker compose restart airflow-webserver

# Rebuild after code/Dockerfile changes
docker compose down
docker compose build
docker compose up -d

# Pull latest code then rebuild
git pull
docker compose down
docker compose build
docker compose up -d
```

## Docker — Shell Access

```bash
# Bash into webserver container
docker exec -it airflow-airflow-webserver-1 bash

# Run airflow commands inside container
docker exec -it airflow-airflow-webserver-1 airflow version
docker exec -it airflow-airflow-webserver-1 airflow dags list
docker exec -it airflow-airflow-webserver-1 airflow info
```

## PostgreSQL

```bash
# Connect to Airflow's Postgres
docker exec -it airflow-postgres-1 psql -U airflow -d airflow
```

### Inside psql

```sql
-- List tables
\dt

-- List databases
\l

-- Check Airflow users
SELECT * FROM ab_user;

-- Check DAG runs
SELECT * FROM dag_run ORDER BY start_date DESC LIMIT 10;

-- Check task instances
SELECT * FROM task_instance ORDER BY start_date DESC LIMIT 10;

-- Table row counts
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;

-- Quit
\q
```

## Airflow UI

```
URL:      http://<PUBLIC-IP>:8080
Username: airflow
Password: airflow
```

http://52.23.158.127:8080/home

## Get Public IP (from inside EC2)

```bash
curl checkip.amazonaws.com
```
