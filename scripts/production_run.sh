#!/bin/bash
# =============================================================================
# 5-Day Production Run Scheduler
#
# Usage:
#   ./scripts/production_run.sh <day_number>
#
# Day plan:
#   Day 1: none     — establish baseline (clean data, all metrics nominal)
#   Day 2: normal   — 3% nulls, 2% OOR, 5% dupes (typical production)
#   Day 3: high     — 10% nulls, 8% OOR, 15% dupes (stress test)
#   Day 4: chaos    — 25% nulls, 15% OOR, 30% dupes (resilience test)
#   Day 5: normal   — verify recovery back to normal quality
# =============================================================================

set -euo pipefail

DAY=${1:-}

declare -A PROFILES=(
    [1]="none"
    [2]="normal"
    [3]="high"
    [4]="chaos"
    [5]="normal"
)

declare -A DESCRIPTIONS=(
    [1]="Baseline — clean data, establish nominal metrics"
    [2]="Normal — typical production error rates"
    [3]="High — stress test with elevated error injection"
    [4]="Chaos — maximum error injection, resilience test"
    [5]="Recovery — back to normal, verify pipeline recovers"
)

if [[ -z "$DAY" || ! "${PROFILES[$DAY]+exists}" ]]; then
    echo "Usage: $0 <day_number> (1-5)"
    echo ""
    echo "Day Plan:"
    for d in 1 2 3 4 5; do
        echo "  Day $d: ${PROFILES[$d]} — ${DESCRIPTIONS[$d]}"
    done
    exit 1
fi

PROFILE=${PROFILES[$DAY]}
DESC=${DESCRIPTIONS[$DAY]}

echo "============================================"
echo "  Production Run — Day $DAY"
echo "  Profile: $PROFILE"
echo "  Description: $DESC"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# Trigger the DAG with the day's error profile
echo ""
echo "Triggering iot_pipeline DAG with error_profile=$PROFILE..."

docker exec airflow-airflow-scheduler-1 \
    airflow dags trigger iot_pipeline \
    --conf "{\"error_profile\": \"$PROFILE\", \"run_dbt\": true}"

echo ""
echo "DAG triggered successfully."
echo ""
echo "Next steps:"
echo "  1. Monitor in Airflow UI"
echo "  2. Check Snowflake: SELECT * FROM IOT_PIPELINE.MARTS.rpt_fleet_overview ORDER BY report_date DESC LIMIT 1;"
echo "  3. Check quality:   SELECT * FROM IOT_PIPELINE.MARTS.fct_data_quality ORDER BY batch_ts DESC LIMIT 5;"
echo "  4. Check anomalies: SELECT severity, COUNT(*) FROM IOT_PIPELINE.MARTS.fct_anomalies WHERE detected_at::date = CURRENT_DATE GROUP BY 1;"
echo ""
echo "After Day 5, run the review queries:"
echo "  ./scripts/review_production_run.sh"
