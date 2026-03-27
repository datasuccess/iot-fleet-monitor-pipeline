{% test row_count_anomaly(model, min_count=1, max_deviation_pct=50) %}
{#
    Custom generic dbt test: row_count_anomaly
    -------------------------------------------
    Compares the current row count of a model against the average row count
    over the last 7 days (using Snowflake INFORMATION_SCHEMA query history).

    Parameters:
        model            - the dbt model ref (auto-injected)
        min_count        - minimum absolute row count required (default: 1)
        max_deviation_pct - max allowed % deviation from 7-day avg (default: 50)

    The test FAILS (returns rows) when:
        1. Current row count is below min_count, OR
        2. The deviation from the 7-day average exceeds max_deviation_pct
#}

WITH current_count AS (
    SELECT COUNT(*) AS row_count
    FROM {{ model }}
),

historical_avg AS (
    -- Approximate historical volume from past query results on this table.
    -- Falls back to current count if no history is available.
    SELECT COALESCE(AVG(rows_produced), 0) AS avg_row_count
    FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
        DATE_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP()),
        DATE_RANGE_END   => CURRENT_TIMESTAMP(),
        RESULT_LIMIT     => 1000
    ))
    WHERE QUERY_TEXT ILIKE '%{{ model }}%'
      AND QUERY_TYPE = 'SELECT'
      AND ROWS_PRODUCED > 0
),

validation AS (
    SELECT
        c.row_count AS current_rows,
        COALESCE(NULLIF(h.avg_row_count, 0), c.row_count) AS avg_rows,
        CASE
            WHEN COALESCE(NULLIF(h.avg_row_count, 0), c.row_count) = 0 THEN 0
            ELSE ROUND(
                100.0 * ABS(c.row_count - COALESCE(NULLIF(h.avg_row_count, 0), c.row_count))
                / COALESCE(NULLIF(h.avg_row_count, 0), c.row_count),
                2
            )
        END AS deviation_pct
    FROM current_count c
    CROSS JOIN historical_avg h
)

SELECT
    current_rows,
    avg_rows,
    deviation_pct
FROM validation
WHERE current_rows < {{ min_count }}
   OR deviation_pct > {{ max_deviation_pct }}

{% endtest %}
