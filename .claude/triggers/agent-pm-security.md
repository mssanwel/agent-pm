# Agent PM — Daily Security Audit Trigger

**Schedule:** Daily at 19:00 local time via launchd (`com.mssanwel.agent-pm.security`).
**Role:** Compare today's system snapshot against the baseline, produce a report, file a Linear issue **only** if anomalies are found.

## Input

Before the LLM runs, `scripts/run-security-audit.sh` has already collected raw data into a temp file. That file path is passed in the prompt as `$SNAPSHOT_FILE`. Its format is a simple INI-style text dump with sections:

```
[processes]
PID COMMAND...

[launchd]
STATUS LABEL

[network]
PROCESS PID LOCAL_ADDR REMOTE_ADDR

[files_protected_paths]
TIMESTAMP PATH           # recent modifications in ~/.ssh, keychains, etc.

[files_allowed_paths]
TIMESTAMP PATH           # recent modifications in expected agent workspaces

[git_state]
STATUS_OR_COMMIT_INFO

[agent_pm]
KEY=VALUE               # required_files_ok, forbidden_files_found, pause_flag, ...

[cost]
today_usd=<n>
yesterday_usd=<n>
```

## Instructions

### 1. Load inputs

- Read the baseline: `~/code/agent-pm/.claude/agent-pm/security-baseline.yaml`
- Read the snapshot: the path provided as `$SNAPSHOT_FILE`

### 2. Classify each section

For each section in the snapshot, classify findings into three buckets:

| Level | Meaning | Action |
|---|---|---|
| 🟢 GREEN | Matches baseline | Summarise in 1 line |
| 🟡 YELLOW | Unusual but explainable (new user-prefix plist, VPN IP, heavy day) | Note in report; no escalation |
| 🔴 RED | Clear anomaly — unknown plist, unrecognised IP, write to protected path, unknown git author, forbidden file present, cost spike >3× yesterday | Include in anomaly block |

Rules of thumb:
- launchd job NOT in `launchd_jobs.expected_labels` AND NOT starting with a prefix in `expected_prefixes` → 🔴
- network destination not matching any pattern in `network.allowed_host_patterns` → 🔴
- write to anything under `files.protected_paths` → 🔴
- presence of any `agent_pm_state.forbidden_files` → 🔴
- `cost.today_usd > cost.daily_spike_multiplier * cost.yesterday_usd` AND today_usd > $1 → 🔴 (ignore small noise)
- `cost.today_usd >= cost.absolute_ceiling_usd` → 🔴
- git commit in last 24h with an author outside `git.expected_authors` → 🔴
- unexpected `claude` binary path (anything not `/opt/homebrew/bin/claude` or `/usr/local/bin/claude`) → 🔴

### 3. Write the report

Write a markdown report to `~/code/agent-pm/.claude/agent-pm/security-reports/YYYY-MM-DD.md`. Use this structure:

```markdown
# Security Audit — YYYY-MM-DD HH:MM TZ

## Summary
- Overall: 🟢 CLEAR | 🟡 SOFT FLAGS | 🔴 ANOMALIES FOUND
- Processes: <n>
- Network destinations: <n> hosts
- launchd jobs: <n> loaded
- File writes in protected paths: <n>
- Today's agent-pm cost: $<n> (vs yesterday $<n>)

## Findings
<one line per finding, grouped GREEN / YELLOW / RED>

## Anomalies (if any)
<detailed block per RED finding: what was expected, what was seen, suggested next step>

— Agent PM (security)
```

### 4. Emit structured marker for the bash runner

After writing the report, emit exactly one line to stdout:

```
SECURITY_STATUS: CLEAR
```

or

```
SECURITY_STATUS: ANOMALIES   report_path=<abs-path>
```

The bash runner reads this marker and, on `ANOMALIES`, creates a Linear issue titled `Agent PM — security anomaly <date>` with label `agent-pm` + `ops` in `Human Review`, body = the anomaly block from the report.

### 5. Emit heartbeat

Per the normal Phase 5 rule, emit one `HEARTBEAT_JSON:` line for the bash runner to append. Include `{"kind":"security"}` in the JSON to distinguish these runs.

## Rules

- Do NOT write to Linear directly. The bash runner creates the issue only on anomalies.
- Do NOT modify `security-baseline.yaml`. If the baseline is wrong, flag it as a YELLOW finding; the human updates it.
- Keep the report concise. Findings in the baseline = one line. Details only for anomalies.
- Sign as `— Agent PM (security)` to distinguish from dispatch runs.
