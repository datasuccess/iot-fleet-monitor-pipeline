# Connections & Credentials

## Airflow
- **URL**: http://52.23.158.127:8080
- **Username**: airflow
- **Password**: airflow
- **EC2 Instance ID**: i-01182aa00d50da692

get ec2 public ip::::

aws ec2 describe-instances --instance-ids i-01182aa00d50da692 --query 'Reservations[].Instances[].PublicIpAddress' --output text

## EC2
- **Public IP**: 52.23.158.127 *(changes on stop/start unless Elastic IP attached)*
- **SSH**: `

ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@54.236.21.107

`
- **Region**: us-east-1
- **Instance Type**: t4g.small (ARM/Graviton)

## S3
- **Bucket**: iot-fleet-monitor-data
- **Raw path**: `s3://iot-fleet-monitor-data/sensor_readings/year=YYYY/month=MM/day=DD/hour=HH/`
- **Iceberg path**: `s3://iot-fleet-monitor-data/iceberg/iot_pipeline/`

## Snowflake
- **Account**: swtivtz-cj19299
- **Account Locator**: MM75901
- **Region**: AWS_EU_CENTRAL_1
- **Database**: IOT_PIPELINE
- **Warehouse**: IOT_WH
- **User**: DRONQO39
- **Roles**: IOT_LOADER, IOT_TRANSFORMER, IOT_READER

## Lambda
- **Function name**: iot-fleet-data-generator
- **Region**: us-east-1
- **Runtime**: Python 3.11 (ARM64)

## dbt
- **Profile**: iot_pipeline
- **Project**: iot_pipeline
- **Packages**: dbt_utils, dbt_expectations
