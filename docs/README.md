# IoT Fleet Monitor Pipeline — Documentation

## Concepts & Deep Dives
| File | Topic |
|------|-------|
| [data-engineering.md](data-engineering.md) | ETL vs ELT, data architectures, ACID, file formats, orchestration patterns |
| [data-modeling.md](data-modeling.md) | Star vs Snowflake vs Data Vault vs OBT — pros/cons/when-to-use |
| [schema-evolution.md](schema-evolution.md) | Zero-downtime schema changes, backfill strategies |
| [streaming.md](streaming.md) | Kafka concepts, batch vs streaming, Lambda vs Kappa architecture |
| [recovery.md](recovery.md) | Pipeline recovery and resilience patterns |

## Component Guides
| File | Topic |
|------|-------|
| [lambda.md](lambda.md) | AWS Lambda data generator — design, error profiles, deployment |
| [snowflake.md](snowflake.md) | Snowflake setup — stages, pipes, streams, tasks, Iceberg |
| [airflow.md](airflow.md) | Airflow — DAG design, Cosmos, branching, SLA, testing |
| [dbt.md](dbt.md) | dbt — staging, intermediate, marts, snapshots, macros, tests |
| [monitoring.md](monitoring.md) | Observability, alerting, data quality scoring |

## Project
| File | Topic |
|------|-------|
| [project.md](project.md) | Specification, data model, ER diagram, lineage, object model |
| [todo.md](todo.md) | Phase-by-phase progress tracker |
| [testing.md](testing.md) | Testing strategy |
| [infrastructure.md](infrastructure.md) | EC2 setup, connections, credentials, commands |

## Interview Prep
| File | Topic |
|------|-------|
| [interview-qa.md](interview-qa.md) | 15+ Q&A for senior DE / data architect interviews |
