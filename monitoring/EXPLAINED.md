# Monitoring, Tooling & Data Quality — Concepts Explained

Everything in this file is written to help you understand the "why" and "how" behind each tool and concept used in this project.

---

## 1. Data Observability — Watching Your Data, Not Just Your Code

### The Problem

A pipeline can run "successfully" — no errors, green status in Airflow — while producing **completely wrong results**. Your code works fine, but:
- S3 had stale files → you loaded yesterday's data again
- A sensor firmware update changed JSON field names → NULLs everywhere
- A device cluster went offline → only 30 of 50 devices reporting

**Application monitoring** (Datadog, Grafana) watches servers and processes.
**Data observability** watches the data itself.

### The 5 Pillars of Data Observability

| Pillar | Question It Answers | Our Project Example |
|--------|--------------------|--------------------|
| **Freshness** | Is the data up to date? | `iot_monitoring_dag` checks if `max(loaded_at)` is within 2 hours |
| **Volume** | Did we get the expected amount? | `test_row_count_anomaly` compares today's count vs 7-day average |
| **Distribution** | Do values look normal? | Z-score anomaly detection in `int_readings_validated` |
| **Schema** | Did the data structure change? | `TRY_CAST` in staging returns NULL instead of erroring on new types |
| **Lineage** | Where did this data come from? What breaks if it's wrong? | dbt's `ref()` builds the dependency graph automatically |

### How We Implement Each Pillar

**Freshness**: Two layers of checking:
1. Snowflake Task (`06_tasks.sql`) — runs every 30 min inside Snowflake, checks `max(loaded_at)`
2. Airflow monitoring DAG — independent check from outside Snowflake

Why two? If Snowflake itself is down, the internal task can't alert you. The Airflow check catches that.

**Volume**: The `test_row_count_anomaly` macro compares current row count against the 7-day moving average. If today's count deviates more than 50%, the test fails. This catches:
- Partial loads (only half the devices reported)
- Duplicate loads (count doubled)
- Empty loads (Lambda failed silently)

**Distribution**: Z-scores in `int_readings_validated`:
```sql
(temperature - avg(temperature) over last_12_readings)
/ stddev(temperature) over last_12_readings
```
A z-score > 3 means the value is in the 0.3% tail — extremely unusual. This catches gradual sensor drift that range checks miss.

---

## 2. Alert Threshold Design

### The #1 Problem: Alert Fatigue

When everything alerts, nothing alerts. If your team gets 50 alerts/day, they stop reading them. Then the one critical alert at 2 AM gets ignored.

### Two-Tier System: Warn vs Critical

Defined in `monitoring/alerts/alert_rules.yml`:

```yaml
data_freshness:
  warn: 60 minutes    # → Slack notification, investigate when convenient
  critical: 120 minutes # → PagerDuty, wake someone up
```

| Level | Action | Channel | Response Time |
|-------|--------|---------|---------------|
| **Warn** | Investigate when convenient | Slack channel, email digest | Hours |
| **Critical** | Act now | PagerDuty, phone call | Minutes |

### Design Principles

1. **Start lenient, tighten later.** Set thresholds high initially. After 2 weeks of data, look at the actual distribution and adjust. It's better to miss an early alert than to burn out your team.

2. **Base thresholds on observed data.** Don't guess. Run:
   ```sql
   SELECT
       PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY quality_score) as p5,
       PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY quality_score) as median,
       AVG(quality_score) as mean
   FROM fct_data_quality
   ```
   Set warn at p5 (5th percentile), critical well below that.

3. **Every alert must have a runbook.** When an alert fires, the engineer should know:
   - What does this mean?
   - What should I check first?
   - How do I fix it?
   - Who should I escalate to?

4. **Aggregate before alerting.** Don't alert on every single anomaly. Alert when the anomaly *rate* exceeds a threshold. One bad reading = noise. Fifty bad readings in an hour = signal.

---

## 3. Quality Scoring — One Number to Rule Them All

### Why a Single Score?

Tracking 15 individual metrics is overwhelming. A quality score combines them into one 0-100 number that's easy to:
- Trend on a dashboard
- Set alerts on
- Report to stakeholders ("data quality was 94% this week")

### Our Formula (`fct_data_quality`)

```
quality_score = 100
  - (null_pct × 0.5)           -- Nulls are bad but not catastrophic
  - (duplicate_pct × 0.3)      -- Dupes waste compute but don't corrupt results
  - (quarantine_pct × 0.2)     -- Quarantined records are caught, so lower penalty
```

**Why weighted?** Different issues have different impacts:
- A null temperature means you **lose** a data point
- A duplicate means you **double-count** a data point (worse for aggregations)
- A quarantined record was **caught and removed** — the system worked

### The Trend Matters More Than the Number

A score of 82 today? Fine.
A score that dropped from 95 to 82 over 3 days? Investigate immediately.

Always look at the **direction** and **rate of change**, not just the absolute value.

---

## 4. SQLFluff — SQL Linter (Spell-Check for SQL)

### What Is a Linter?

A linter is a tool that analyzes your code for:
- **Style issues**: inconsistent formatting, casing
- **Potential bugs**: ambiguous joins, missing aliases
- **Best practice violations**: `SELECT *`, implicit column ordering

It's like a spell-checker but for code. It doesn't run your SQL — it reads it and points out problems.

### Why SQL Needs a Linter

Without a linter, your team writes SQL 5 different ways:

```sql
-- Person A: everything on one line
select device_id,temperature,humidity from readings where battery_pct<10

-- Person B: keywords uppercase, 4-space indent
SELECT
    device_id,
    temperature,
    humidity
FROM readings
WHERE battery_pct < 10

-- Person C: lowercase keywords, 2-space indent, trailing commas
select
  device_id
  , temperature
  , humidity
from readings
where battery_pct < 10
```

Code reviews become arguments about style instead of logic. SQLFluff makes everyone write the same way.

### Our Configuration (`.sqlfluff`)

```ini
[sqlfluff]
dialect = snowflake        # Knows VARIANT, FLATTEN, LATERAL, etc.
templater = dbt            # Understands {{ ref() }}, {% if %}, macros
max_line_length = 120      # Wide enough for readable queries

[sqlfluff:rules:capitalisation.keywords]
capitalisation_policy = upper    # SELECT, FROM, WHERE (not select, from, where)

[sqlfluff:rules:capitalisation.identifiers]
capitalisation_policy = lower    # device_id, temperature (not DEVICE_ID)
```

**Why Snowflake dialect?** Generic SQL linters don't understand:
- `VARIANT` data type
- `$1:field_name` notation
- `FLATTEN()` function
- `QUALIFY` clause
- `MATCH_RECOGNIZE` etc.

SQLFluff with `dialect = snowflake` knows all of these.

**Why dbt templater?** Without it, SQLFluff sees `{{ ref('stg_sensor_readings') }}` and thinks it's a syntax error. The dbt templater tells SQLFluff "this is a Jinja template, resolve it before linting."

### Running SQLFluff

```bash
# Check for issues (doesn't change files)
sqlfluff lint dbt/iot_pipeline/models/
# Output:
# == [dbt/iot_pipeline/models/marts/fct_anomalies.sql] FAIL
# L044 | Query produces an unused CTE.
# L010 | Keywords must be upper case. Found 'select' not 'SELECT'.

# Auto-fix what it can (changes files in place)
sqlfluff fix dbt/iot_pipeline/models/

# Lint a single file
sqlfluff lint dbt/iot_pipeline/models/marts/fct_device_health.sql
```

### Common SQLFluff Rules

| Rule | What It Catches | Example |
|------|----------------|---------|
| L010 | Keyword casing | `select` → `SELECT` |
| L014 | Identifier casing | `Device_ID` → `device_id` |
| L016 | Line too long | Lines > 120 chars |
| L032 | Prefer `COALESCE` over `IFNULL`/`NVL` | More portable SQL |
| L042 | Subquery without alias | `FROM (SELECT ...) AS t` |
| L044 | Unused CTE | CTE defined but never referenced |

---

## 5. Pre-commit Hooks — The Safety Net Before Git

### What Is Pre-commit?

`pre-commit` is a framework that runs checks **automatically before every `git commit`**. If any check fails, the commit is blocked.

```
You write code
  → git add .
  → git commit -m "update model"
  → pre-commit hooks run automatically
    → SQLFluff: PASSED ✓
    → Ruff: PASSED ✓
    → detect-secrets: FAILED ✗ (found API key on line 42!)
  → Commit BLOCKED — fix the issue first
```

### Why It Matters

| Without pre-commit | With pre-commit |
|-------------------|-----------------|
| Bad SQL formatting gets committed | Caught and auto-fixed before commit |
| Passwords accidentally committed | Blocked by detect-secrets |
| Broken YAML configs committed | Caught by check-yaml |
| Found in code review (hours/days later) | Found immediately (seconds) |

The earlier you catch a problem, the cheaper it is to fix:
- **At commit time**: 10 seconds to fix
- **In code review**: 30 minutes (context switch, discussion, re-review)
- **In production**: Hours to days (incident, rollback, post-mortem)

### Our Hooks (`.pre-commit-config.yaml`)

#### Basic Checks (instant)
| Hook | What It Does |
|------|-------------|
| `trailing-whitespace` | Removes trailing spaces from line endings. These cause noisy git diffs — a line looks "changed" when only a space was added. |
| `end-of-file-fixer` | Ensures every file ends with a newline. POSIX standard — some tools break without it. |
| `check-yaml` | Validates YAML syntax. Catches missing colons, bad indentation in `dbt_project.yml`, `docker-compose.yml`, etc. |

#### SQL Quality
| Hook | What It Does |
|------|-------------|
| `sqlfluff-lint` | Checks SQL files against our style rules. Reports violations. |
| `sqlfluff-fix` | Auto-fixes SQL formatting issues. Saves you manual work. |

#### Python Quality
| Hook | What It Does |
|------|-------------|
| `ruff check` | Python linter — catches unused imports, undefined variables, bad syntax. 10-100x faster than flake8. |
| `ruff format` | Python formatter — consistent style like `black` but faster. |

#### Security
| Hook | What It Does |
|------|-------------|
| `detect-secrets` | Scans for patterns that look like passwords, API keys, tokens. Blocks commit if found. This is critical — once a secret is in git history, it's very hard to remove (even if you delete it in the next commit, it's still in the history). |

### Setup (One-Time Per Machine)

```bash
# Install the tool
pip install pre-commit

# Install hooks into this repo's .git/hooks/
cd iot-fleet-monitor-pipeline
pre-commit install

# Test on all existing files (good to run once)
pre-commit run --all-files

# Now every 'git commit' automatically runs the hooks
```

### What If a Hook Fails?

```bash
$ git commit -m "add new model"

sqlfluff-lint..........FAILED
- hook id: sqlfluff-lint
- files were modified by this hook

# SQLFluff auto-fixed the files. Now:
$ git add .                     # Stage the auto-fixed files
$ git commit -m "add new model" # Try again — should pass now
```

For `detect-secrets` failures, you need to either:
1. Remove the secret and use environment variables instead
2. Mark it as a false positive in `.secrets.baseline`

### Pro Tips

- **Run `pre-commit run --all-files` after cloning** — catches existing issues
- **Add to CI/CD too** — pre-commit only runs on your machine. Someone could skip it with `git commit --no-verify`. CI is the backstop.
- **Don't disable hooks** — if a hook is annoying, fix the config, don't remove the hook

---

## 6. Ruff — Python Linter & Formatter

### What Is Ruff?

Ruff replaces 3 Python tools in one:
- **flake8** (linting — find bugs and style issues)
- **isort** (import sorting)
- **black** (code formatting)

It's written in Rust, so it's 10-100x faster than the Python alternatives.

### What It Catches

```python
# Unused import — ruff catches this
import os  # ← "F401: os imported but unused"

# Undefined variable
print(resualt)  # ← "F821: undefined name 'resualt'"

# Style issues
x=1  # ← "E225: missing whitespace around operator"
```

### Ruff in Our Project

We use two commands:
- `ruff check` — Find issues (like flake8)
- `ruff format` — Auto-format code (like black)

Both run automatically via pre-commit on every git commit.

---

## 7. detect-secrets — Never Commit Passwords

### The Problem

It's disturbingly easy to commit secrets:

```python
# Oops, hardcoded during debugging
SNOWFLAKE_PASSWORD = "39044093Toghrul!"
AWS_SECRET_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

Once it's in git history, **anyone with repo access can see it forever** — even if you delete it in the next commit. The only fix is to rotate the credential and rewrite git history (painful).

### How detect-secrets Works

It scans files for patterns that look like secrets:
- High-entropy strings (random characters = likely a key)
- Known patterns (`AKIA...` = AWS access key, `ghp_...` = GitHub token)
- Common variable names (`password`, `secret`, `api_key`)

If it finds something, it blocks the commit:
```
detect-secrets..........FAILED
Potential secret found in airflow/dags/helpers/snowflake_utils.py:14
```

### The Right Way: Environment Variables

Instead of hardcoding:
```python
# BAD — secret in code
conn = snowflake.connector.connect(password="39044093Toghrul!")

# GOOD — secret in environment variable
conn = snowflake.connector.connect(password=os.environ["SNOWFLAKE_PASSWORD"])
```

The `.env` file (which has the actual values) is in `.gitignore` and never committed. The `.env.example` file (with placeholder values) is committed so new developers know what variables to set.

---

## 8. Monitoring Dashboard Design

### Our Dashboard (`monitoring/dashboards/quality_dashboard.sql`)

8 panels designed for Snowflake Snowsight:

| Panel | What It Shows | Why It Matters |
|-------|-------------|----------------|
| Quality Trend | quality_score over 7 days | Spot degradation early |
| Anomaly Summary | Count by severity + sensor | Where are the problems? |
| Fleet Health | Devices by status (healthy/warning/critical) | How many devices need attention? |
| Battery Heatmap | Battery levels per device, 3 days | Predict which devices die next |
| Hourly Volume | Readings per hour, 24h | Spot missing hours |
| Fleet KPIs | Latest rpt_fleet_overview row | Executive summary |
| Quarantine Rate | quarantined/total over 7 days | Is data quality improving or degrading? |
| Top Anomaly Devices | Top 10 by anomaly count | Which devices to investigate first |

### Dashboard Design Principles

1. **Top-to-bottom = high-level to detailed.** First panel = overall health. Last panel = drill-down details.
2. **Time-series for trends, tables for details.** Line charts show direction. Tables show specifics.
3. **Color = severity.** Red = critical, yellow = warning, green = healthy. Universal convention.
4. **Default to last 24h or 7 days.** Short enough to see recent changes, long enough to spot trends.

---

## 9. Putting It All Together — The Quality Feedback Loop

```
Data arrives
  → Staging (TRY_CAST catches schema issues)
  → Intermediate (validation catches bad values, quarantine preserves evidence)
  → Marts (quality scorecard quantifies health)
  → Monitoring DAG (checks freshness, quality, anomalies)
  → Alerts (warn/critical thresholds trigger notifications)
  → Dashboard (human reviews and investigates)
  → Fix (update thresholds, fix sensors, adjust pipeline)
  → Data arrives (loop repeats)
```

This is a **feedback loop**. The monitoring isn't just watching — it drives improvement:
- High quarantine rate → investigate which sensors → replace faulty devices
- Quality score trending down → check what changed → fix the root cause
- Anomaly spike → correlate with events → adjust thresholds

The goal isn't zero errors. The goal is **catching errors fast and understanding why they happen**.
