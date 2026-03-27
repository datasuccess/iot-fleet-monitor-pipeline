# Monitoring & Data Quality — Concepts Explained

This document breaks down the monitoring and quality concepts used in this project so you can understand the "why" behind each piece.

---

## 1. Data Observability

**What it is:** Data observability is the ability to understand, diagnose, and manage data health across your pipeline — similar to how application monitoring (like Datadog or Grafana) watches your servers, but focused on the *data itself*.

**Why it matters:** Bad data is often silent. A pipeline can run "successfully" (no errors, green status) while producing completely wrong results. Observability gives you eyes on what the data actually looks like.

### The 5 Pillars

| Pillar | Question It Answers | Example in This Project |
|---|---|---|
| **Freshness** | Is the data up to date? | "Our latest sensor reading is 3 hours old — that's a problem." |
| **Volume** | Did we get the expected amount of data? | "We normally ingest ~10,000 readings/hour. Today we got 200." |
| **Distribution** | Do the values look normal? | "Average temperature jumped from 22C to 85C — anomaly or real?" |
| **Schema** | Did the structure of the data change? | "The `battery_pct` column is suddenly missing from incoming JSON." |
| **Lineage** | Where did this data come from and what depends on it? | "If raw readings are wrong, which dashboards are affected?" |

In this project, we address these pillars through:
- `fct_data_quality` — tracks freshness, volume, and quarantine rates
- `fct_anomalies` — catches distribution problems
- `fct_device_health` — monitors device-level health signals
- dbt's built-in lineage graph — shows the dependency chain

---

## 2. Alert Threshold Design

Alerts are only useful if people actually pay attention to them. The single biggest mistake in monitoring is creating too many alerts, which leads to **alert fatigue** — when people start ignoring alerts because most of them are noise.

### Warn vs. Critical

We use a two-tier system defined in `alert_rules.yml`:

- **Warn:** Something is off and worth investigating, but not urgent. These might go to a Slack channel or an email digest. Example: quality score drops to 75 (below the 80 threshold but still functional).

- **Critical:** Something is broken and needs immediate attention. These should page someone or block downstream processes. Example: quality score drops to 50 (data is unreliable).

### Design Principles

1. **Start lenient, tighten later.** It's better to miss an early alert than to burn out your team. You can always lower thresholds once you understand normal variance.

2. **Base thresholds on observed data.** Don't guess — look at your actual quality score distribution over a few weeks, then set "warn" at the low end of normal and "critical" at the point where action is clearly needed.

3. **Every alert must have a clear action.** If there's nothing someone can do when the alert fires, it shouldn't be an alert — it should be a dashboard metric.

---

## 3. Quality Scoring

Rather than tracking dozens of individual metrics, a **quality score** combines multiple signals into a single 0-100 number that's easy to trend and alert on.

### Weighted Formula Approach

A typical formula might look like:

```
quality_score = (
    0.30 * completeness_score +    -- Are all expected fields present?
    0.25 * validity_score +        -- Do values pass validation rules?
    0.20 * freshness_score +       -- Is the data recent enough?
    0.15 * uniqueness_score +      -- Are there unexpected duplicates?
    0.10 * consistency_score       -- Do cross-field checks pass?
)
```

The weights reflect what matters most for your use case. For IoT sensor data, completeness and validity are typically weighted highest because missing or invalid readings directly affect downstream analytics.

**Key insight:** The score itself is less important than the *trend*. A score of 82 is fine. A score that dropped from 95 to 82 in two days is a red flag worth investigating.

---

## 4. Pre-commit Hooks

**What they are:** Pre-commit hooks are scripts that run automatically every time you run `git commit`. If the hook fails, the commit is blocked until you fix the issue.

**Why they matter:** They catch problems *before* code enters the repository, which is much cheaper than catching them in code review or — worse — in production.

### Hooks in This Project

| Hook | Purpose |
|---|---|
| `trailing-whitespace` | Removes trailing spaces (prevents noisy diffs) |
| `end-of-file-fixer` | Ensures files end with a newline (POSIX standard) |
| `check-yaml` | Validates YAML syntax (catches broken config files early) |
| `sqlfluff-lint` | Checks SQL against style rules |
| `sqlfluff-fix` | Auto-fixes SQL style violations |
| `ruff` | Lints Python code (fast replacement for flake8 + isort) |
| `ruff-format` | Auto-formats Python code (fast replacement for black) |
| `detect-secrets` | Scans for accidentally committed passwords/keys |

### How to Set Up

```bash
pip install pre-commit
pre-commit install          # one-time setup per repo clone
pre-commit run --all-files  # test it on all existing files
```

After `pre-commit install`, hooks run automatically on every `git commit`.

---

## 5. SQLFluff — SQL Linting

**What it is:** SQLFluff is a linter and auto-formatter for SQL, similar to what `ruff` or `black` does for Python. It enforces consistent SQL style across a team.

**Why it matters in data engineering:** Data teams often have many people writing SQL with different styles. Without a linter, you end up with:
- Mixed keyword casing (`SELECT` vs `select` vs `Select`)
- Inconsistent indentation
- Trailing commas in some files, leading commas in others
- Hard-to-review pull requests because of style noise

### Key Config Choices (`.sqlfluff`)

| Setting | Value | Why |
|---|---|---|
| `dialect` | `snowflake` | Enables Snowflake-specific syntax (e.g., `FLATTEN`, `VARIANT`) |
| `templater` | `dbt` | Understands `{{ ref() }}` and Jinja so it doesn't flag them as errors |
| `max_line_length` | `120` | Long enough for readable queries, short enough to avoid horizontal scrolling |
| `capitalisation.keywords` | `upper` | Industry convention — `SELECT`, `FROM`, `WHERE` in uppercase |
| `capitalisation.identifiers` | `lower` | Column/table names in lowercase — matches Snowflake's default behavior |

### Running It

```bash
# Check for issues
sqlfluff lint dbt/iot_pipeline/models/

# Auto-fix what it can
sqlfluff fix dbt/iot_pipeline/models/
```

SQLFluff won't catch logical bugs — it's purely about style and syntax. Think of it as spell-check for SQL.
