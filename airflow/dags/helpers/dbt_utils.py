"""
dbt subprocess wrapper - fallback if Cosmos has issues.
"""

import logging
import subprocess

logger = logging.getLogger("airflow.dbt_utils")

VALID_COMMANDS = {"run", "test", "snapshot", "seed", "source", "build", "compile", "debug"}


def run_dbt_command(
    command,
    project_dir="/opt/airflow/dbt/iot_pipeline",
    profiles_dir="/opt/airflow/dbt/iot_pipeline",
    target="prod",
):
    """
    Run a dbt command via subprocess.

    Args:
        command: dbt command to run (run, test, snapshot, seed, source freshness, etc.)
        project_dir: path to dbt project directory
        profiles_dir: path to directory containing profiles.yml
        target: dbt target name

    Returns:
        dict with keys: success (bool), stdout (str), stderr (str)
    """
    base_command = command.split()[0]
    if base_command not in VALID_COMMANDS:
        raise ValueError(
            f"Invalid dbt command: '{base_command}'. Must be one of: {VALID_COMMANDS}"
        )

    cmd = [
        "/home/airflow/.local/bin/dbt",
        *command.split(),
        "--project-dir", project_dir,
        "--profiles-dir", profiles_dir,
        "--target", target,
    ]

    logger.info("Running dbt command: %s", " ".join(cmd))

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=600,
        )

        if result.stdout:
            for line in result.stdout.strip().splitlines():
                logger.info("[dbt] %s", line)

        if result.stderr:
            for line in result.stderr.strip().splitlines():
                logger.warning("[dbt stderr] %s", line)

        success = result.returncode == 0
        if not success:
            logger.error("dbt command failed with return code %d", result.returncode)

        return {
            "success": success,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }

    except subprocess.TimeoutExpired:
        logger.error("dbt command timed out after 600 seconds")
        return {
            "success": False,
            "stdout": "",
            "stderr": "Command timed out after 600 seconds",
        }
    except Exception as e:
        logger.error("Failed to run dbt command: %s", str(e))
        return {
            "success": False,
            "stdout": "",
            "stderr": str(e),
        }
