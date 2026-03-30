-- =============================================================================
-- Compare Batch (COPY INTO) vs Streaming (Kafka Consumer) data
-- Run in Snowsight after both pipelines have been running
-- =============================================================================

USE ROLE IOT_TRANSFORMER;
USE WAREHOUSE IOT_WH;
USE DATABASE IOT_PIPELINE;

-- 1. Row counts
SELECT 'batch (COPY INTO)' AS pipeline, COUNT(*) AS rows,
       MIN(loaded_at) AS first_load, MAX(loaded_at) AS last_load
FROM RAW.sensor_readings
UNION ALL
SELECT 'streaming (Kafka)', COUNT(*), MIN(loaded_at), MAX(loaded_at)
FROM RAW.sensor_readings_streaming;

-- 2. Latency comparison
-- Batch: latency = time between reading_ts and loaded_at (includes S3 + COPY INTO wait)
-- Streaming: latency = time between reading_ts and loaded_at (nearly real-time)
SELECT 'batch' AS pipeline,
       AVG(DATEDIFF(second, raw_data:reading_ts::timestamp, loaded_at)) AS avg_latency_seconds,
       MAX(DATEDIFF(second, raw_data:reading_ts::timestamp, loaded_at)) AS max_latency_seconds,
       MIN(DATEDIFF(second, raw_data:reading_ts::timestamp, loaded_at)) AS min_latency_seconds
FROM RAW.sensor_readings
WHERE loaded_at >= DATEADD(hour, -6, CURRENT_TIMESTAMP())
UNION ALL
SELECT 'streaming',
       AVG(DATEDIFF(second, raw_data:reading_ts::timestamp, loaded_at)),
       MAX(DATEDIFF(second, raw_data:reading_ts::timestamp, loaded_at)),
       MIN(DATEDIFF(second, raw_data:reading_ts::timestamp, loaded_at))
FROM RAW.sensor_readings_streaming
WHERE loaded_at >= DATEADD(hour, -6, CURRENT_TIMESTAMP());

-- 3. Throughput per minute
SELECT 'batch' AS pipeline,
       DATE_TRUNC('minute', loaded_at) AS minute,
       COUNT(*) AS rows_per_minute
FROM RAW.sensor_readings
WHERE loaded_at >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
GROUP BY 1, 2
UNION ALL
SELECT 'streaming',
       DATE_TRUNC('minute', loaded_at),
       COUNT(*)
FROM RAW.sensor_readings_streaming
WHERE loaded_at >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY minute DESC;

-- 4. Kafka metadata (only available on streaming table)
SELECT source_partition,
       COUNT(*) AS messages,
       MIN(source_offset) AS min_offset,
       MAX(source_offset) AS max_offset
FROM RAW.sensor_readings_streaming
GROUP BY source_partition
ORDER BY source_partition;
