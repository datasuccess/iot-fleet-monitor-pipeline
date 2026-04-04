# IoT Fleet Monitor Pipeline — Documentation

## Concepts & Deep Dives
| File | Topic |
|------|-------|
| [EXPLAINED_DATA_ENGINEERING.md](EXPLAINED_DATA_ENGINEERING.md) | ETL vs ELT, data architectures, ACID, surrogate keys, dim_time |
| [EXPLAINED_DATA_MODELING.md](EXPLAINED_DATA_MODELING.md) | Star vs Snowflake vs Data Vault vs OBT — pros/cons/when-to-use |
| [EXPLAINED_SCHEMA_EVOLUTION.md](EXPLAINED_SCHEMA_EVOLUTION.md) | Zero-downtime schema changes, backfill strategies |
| [EXPLAINED_STREAMING.md](EXPLAINED_STREAMING.md) | Kafka concepts, batch vs streaming, Lambda vs Kappa architecture |
| [EXPLAINED_RECOVERY.md](EXPLAINED_RECOVERY.md) | Pipeline recovery and resilience patterns |

## Component Guides
| File | Topic |
|------|-------|
| [EXPLAINED_LAMBDA.md](EXPLAINED_LAMBDA.md) | AWS Lambda data generator — design, error profiles, deployment |
| [EXPLAINED_SNOWFLAKE.md](EXPLAINED_SNOWFLAKE.md) | Snowflake setup — stages, pipes, streams, tasks, Iceberg |
| [EXPLAINED_AIRFLOW.md](EXPLAINED_AIRFLOW.md) | Airflow DAG design — TaskFlow, connections, operators |
| [EXPLAINED_AIRFLOW_PHASE6.md](EXPLAINED_AIRFLOW_PHASE6.md) | Cosmos, branching, trigger rules, SLA callbacks |
| [EXPLAINED_DBT.md](EXPLAINED_DBT.md) | dbt project — staging, intermediate, marts overview |
| [EXPLAINED_DBT_PHASE5.md](EXPLAINED_DBT_PHASE5.md) | Intermediate + marts + snapshots deep dive |
| [EXPLAINED_MONITORING.md](EXPLAINED_MONITORING.md) | Observability, alerting, data quality scoring |

## Project & Planning
| File | Topic |
|------|-------|
| [PROJECT.md](PROJECT.md) | Project overview and goals |
| [PLAN.md](PLAN.md) | Implementation plan |
| [TODO.md](TODO.md) | Phase-by-phase progress tracker |
| [DATA_MODEL.md](DATA_MODEL.md) | Data model documentation |
| [TESTING.md](TESTING.md) | Testing strategy |

## Infrastructure
| File | Topic |
|------|-------|
| [INFRASTRUCTURE.md](INFRASTRUCTURE.md) | Infrastructure setup guide |
| [INFRASTRUCTURE_COMMANDS.md](INFRASTRUCTURE_COMMANDS.md) | Useful commands reference |
| [INFRASTRUCTURE_CONNECTIONS.md](INFRASTRUCTURE_CONNECTIONS.md) | Service connections and endpoints |
| [TEST_INSTRUCTIONS_AIRFLOW.md](TEST_INSTRUCTIONS_AIRFLOW.md) | Airflow testing instructions |

## Interview Prep
| File | Topic |
|------|-------|
| [INTERVIEW_QA.md](INTERVIEW_QA.md) | 15+ Q&A for senior DE / data architect interviews |
