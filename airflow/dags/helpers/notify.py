"""
Callback functions for Airflow DAG/task notifications.
"""

import logging

logger = logging.getLogger("airflow.callbacks")


def on_failure_callback(context):
    """Log task failure details."""
    task_instance = context.get("task_instance")
    dag_id = context.get("dag").dag_id if context.get("dag") else "unknown"
    task_id = task_instance.task_id if task_instance else "unknown"
    execution_date = context.get("execution_date", "unknown")
    exception = context.get("exception", "No exception info")

    logger.error(
        "Task FAILED | dag_id=%s | task_id=%s | execution_date=%s | exception=%s",
        dag_id,
        task_id,
        execution_date,
        exception,
    )


def on_success_callback(context):
    """Log task success."""
    task_instance = context.get("task_instance")
    task_id = task_instance.task_id if task_instance else "unknown"

    logger.info("Task completed successfully | task_id=%s", task_id)


def on_sla_miss_callback(dag, task_list, blocking_task_list, slas, blocking_tis):
    """Log SLA miss details."""
    dag_id = dag.dag_id if dag else "unknown"
    task_ids = [t.task_id for t in task_list] if task_list else []
    blocking_ids = [t.task_id for t in blocking_task_list] if blocking_task_list else []

    logger.error(
        "SLA MISS | dag_id=%s | tasks=%s | blocking_tasks=%s | slas=%s",
        dag_id,
        task_ids,
        blocking_ids,
        slas,
    )
