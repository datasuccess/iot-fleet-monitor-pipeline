# IoT Fleet Monitor Pipeline — Documentation

## Concepts & Deep Dives
| File | Topic |
|------|-------|
| [data-engineering.md](data-engineering.md) | ETL vs ELT, data architectures, ACID, surrogate keys, dim_time |
| [data-modeling.md](data-modeling.md) | Star vs Snowflake vs Data Vault vs OBT — pros/cons/when-to-use |
| [schema-evolution.md](schema-evolution.md) | Zero-downtime schema changes, backfill strategies |
| [streaming.md](streaming.md) | Kafka concepts, batch vs streaming, Lambda vs Kappa architecture |
| [recovery.md](recovery.md) | Pipeline recovery and resilience patterns |

## Component Guides
| File | Topic |
|------|-------|
| [lambda.md](lambda.md) | AWS Lambda data generator — design, error profiles, deployment |
| [snowflake.md](snowflake.md) | Snowflake setup — stages, pipes, streams, tasks, Iceberg |
| [airflow.md](airflow.md) | Airflow DAG design — TaskFlow, connections, operators |
| [airflow-orchestration.md](airflow-orchestration.md) | Cosmos, branching, trigger rules, SLA callbacks |
| [dbt.md](dbt.md) | dbt project — staging, intermediate, marts overview |
| [dbt-intermediate-marts.md](dbt-intermediate-marts.md) | Intermediate + marts + snapshots deep dive |
| [monitoring.md](monitoring.md) | Observability, alerting, data quality scoring |

## Project & Planning
| File | Topic |
|------|-------|
| [project.md](project.md) | Project overview and goals |
| [plan.md](plan.md) | Implementation plan |
| [todo.md](todo.md) | Phase-by-phase progress tracker |
| [data-model.md](data-model.md) | Data model documentation |
| [testing.md](testing.md) | Testing strategy |

## Infrastructure
| File | Topic |
|------|-------|
| [infrastructure.md](infrastructure.md) | Infrastructure setup guide |
| [infrastructure-commands.md](infrastructure-commands.md) | Useful commands reference |
| [infrastructure-connections.md](infrastructure-connections.md) | Service connections and endpoints |
| [airflow-testing.md](airflow-testing.md) | Airflow testing instructions |

## Interview Prep
| File | Topic |
|------|-------|
| [interview-qa.md](interview-qa.md) | 15+ Q&A for senior DE / data architect interviews |
