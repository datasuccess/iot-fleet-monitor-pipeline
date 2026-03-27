#!/usr/bin/env bash
# =============================================================================
# run_daily.sh — Trigger the IoT Fleet Monitor Airflow DAG
# =============================================================================
# Usage:
#   ./scripts/run_daily.sh [error_profile]
#
# Arguments:
#   error_profile   One of: none, normal, high, extreme (default: normal)
#
# Cron example (run every day at 06:00 UTC):
#   0 6 * * * /path/to/iot-fleet-monitor-pipeline/scripts/run_daily.sh normal
# =============================================================================

set -euo pipefail

# -- Configuration ------------------------------------------------------------
DAG_ID="iot_fleet_monitor_pipeline"
ERROR_PROFILE="${1:-normal}"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
LOG_FILE="${LOG_FILE:-/tmp/iot_fleet_daily.log}"

# -- Validate error profile ---------------------------------------------------
VALID_PROFILES=("none" "normal" "high" "extreme")
if [[ ! " ${VALID_PROFILES[*]} " =~ " ${ERROR_PROFILE} " ]]; then
    echo "[${TIMESTAMP}] ERROR: Invalid error_profile '${ERROR_PROFILE}'. Must be one of: ${VALID_PROFILES[*]}" | tee -a "${LOG_FILE}"
    exit 1
fi

# -- Trigger DAG --------------------------------------------------------------
echo "[${TIMESTAMP}] Triggering DAG '${DAG_ID}' with error_profile='${ERROR_PROFILE}'" | tee -a "${LOG_FILE}"

airflow dags trigger "${DAG_ID}" \
    --conf "{\"error_profile\": \"${ERROR_PROFILE}\"}" \
    2>&1 | tee -a "${LOG_FILE}"

EXIT_CODE=${PIPESTATUS[0]}

FINISH_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [ "${EXIT_CODE}" -eq 0 ]; then
    echo "[${FINISH_TIMESTAMP}] DAG triggered successfully." | tee -a "${LOG_FILE}"
else
    echo "[${FINISH_TIMESTAMP}] DAG trigger FAILED with exit code ${EXIT_CODE}." | tee -a "${LOG_FILE}"
    exit "${EXIT_CODE}"
fi
