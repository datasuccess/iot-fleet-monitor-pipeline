# Testing Airflow on EC2

## Step 1: Fill credentials

Edit `airflow/.env` locally — fill in the 5 blank values:
- `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

## Step 2: Push to repo

```bash
# .env is gitignored, so copy it manually to EC2
scp -i ~/.ssh/iot-fleet-pipeline-key.pem \
  airflow/.env \
  ubuntu@<EC2-IP>:/home/ubuntu/iot-pipeline/airflow/.env
```

## Step 3: Rebuild on EC2

```bash
ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@<EC2-IP>

cd /home/ubuntu/iot-pipeline
git pull
cd airflow
docker compose down
docker compose build
docker compose up -d
```

Wait ~2 minutes for containers to start.

## Step 4: Check containers are healthy

```bash
docker compose ps
```

All 3 services should show `healthy` or `running`.

## Step 5: Open Airflow UI

Go to `http://<EC2-IP>:8080` — login: `airflow` / `airflow`

## Step 6: Trigger the DAG

**Option A — UI:**
1. Find `iot_pipeline` DAG in the list
2. Unpause it (toggle switch on the left)
3. Click "Trigger DAG w/ config" (play button with gear icon)
4. Select `error_profile`: `none`
5. Click Trigger

**Option B — CLI (from EC2):**
```bash
docker exec airflow-airflow-webserver-1 \
  airflow dags trigger iot_pipeline \
  --conf '{"error_profile": "none"}'
```

## Step 7: Monitor the run

**UI:** Click into the DAG run → Graph view. You'll see:
- `trigger_lambda` → green = Lambda invoked successfully
- `load_to_snowflake` → green = COPY INTO succeeded
- `validate_load` → green = rows found in RAW table

**CLI:**
```bash
# Check DAG run status
docker exec airflow-airflow-webserver-1 \
  airflow dags list-runs -d iot_pipeline

# Check task logs
docker exec airflow-airflow-webserver-1 \
  airflow tasks logs iot_pipeline trigger_lambda <RUN_ID>
```

## Step 8: Verify in Snowflake

```sql
-- Check rows were loaded
SELECT COUNT(*) FROM IOT_PIPELINE.RAW.sensor_readings;

-- See the latest data
SELECT
    raw_data:device_id::VARCHAR AS device_id,
    raw_data:temperature::FLOAT AS temperature,
    raw_data:reading_ts::TIMESTAMP AS reading_ts,
    loaded_at,
    source_file
FROM IOT_PIPELINE.RAW.sensor_readings
ORDER BY loaded_at DESC
LIMIT 10;
```

## Troubleshooting

**DAG not showing in UI:**
```bash
# Check for import errors
docker exec airflow-airflow-webserver-1 airflow dags list-import-errors
```

**Task failed — check logs:**
```bash
docker compose logs -f airflow-scheduler
```

**Lambda timeout / error:**
- Verify AWS credentials in `.env` are correct
- Test Lambda directly: `aws lambda invoke --function-name iot-fleet-data-generator --payload '{"error_profile":"none"}' --cli-binary-format raw-in-base64-out /tmp/test.json && cat /tmp/test.json`

**Snowflake connection error:**
- Verify Snowflake credentials in `.env`
- Check account format (should be like `abc12345.us-east-1` or your org URL)
