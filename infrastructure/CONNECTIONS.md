# Connections & Credentials

## Airflow
- **URL**: http://52.23.158.127:8080
- **Username**: airflow
- **Password**: airflow
- **EC2 Instance ID**: i-01182aa00d50da692

## EC2
- **Public IP**: 52.23.158.127 *(changes on stop/start unless Elastic IP attached)*
- **SSH**: `ssh -i ~/.ssh/iot-fleet-pipeline-key.pem ubuntu@52.23.158.127`
- **Region**: us-east-1
- **Instance Type**: t4g.small (ARM/Graviton)

## S3
- **Bucket**: *(to be created in Phase 1)*
- **Raw path**: `s3://<bucket>/sensor_readings/year=YYYY/month=MM/day=DD/hour=HH/`
- **Iceberg path**: `s3://<bucket>/iceberg/iot_pipeline/`

## Snowflake
- **Account**: *(to be added in Phase 2)*
- **Database**: IOT_PIPELINE
- **Warehouse**: IOT_WH
- **Roles**: IOT_LOADER, IOT_TRANSFORMER, IOT_READER

## Lambda
- **Function name**: *(to be created in Phase 1)*
- **Region**: us-east-1

## dbt
- **Profile**: *(to be configured in Phase 4)*
- **Project**: iot_pipeline
