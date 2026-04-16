---
description: Control the Agent PM dispatcher — status, pause, resume, config, set, skills, test, log, deploy, doctor
argument-hint: <subcommand> [args]
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, mcp__claude_ai_Linear__list_issues, mcp__claude_ai_Linear__list_comments, mcp__claude_ai_Linear__list_issue_statuses, mcp__claude_ai_Linear__list_issue_labels, mcp__claude_ai_Linear__get_issue, mcp__claude_ai_Linear__get_issue_status]
---

# /agent-pm — Control surface

Interactive control for the Agent PM dispatcher. Invoke with `/agent-pm <subcommand> [args]`.
Running `/agent-pm` with no args prints this help.

The user called: `/agent-pm $ARGUMENTS`

Claude reads this file and executes the branch that matches the subcommand. No separate code.

## Conventions

**All paths are absolute.** The slash command is symlinked into `~/.claude/commands/` so it runs from any cwd — never assume a relative `.claude/` path.

```
REPO_DIR      = ~/code/agent-pm
CONFIG        = ~/code/agent-pm/.claude/agent-pm/config.yaml
REGISTRY      = ~/code/agent-pm/.claude/agent-pm/skill-registry.yaml
LOG           = ~/code/agent-pm/.claude/agent-pm/learning-log.md
HEARTBEAT     = ~/code/agent-pm/.claude/agent-pm/heartbeat.jsonl
PAUSE_FLAG    = ~/code/agent-pm/.claude/agent-pm/pause.flag
DISPATCH_TRIG = ~/code/agent-pm/.claude/triggers/agent-pm-dispatch.md
WEEKLY_TRIG   = ~/code/agent-pm/.claude/triggers/agent-pm-weekly.md
RUNNER_LOG    = ~/code/agent-pm/.claude/agent-pm/logs/dispatch-YYYY-MM-DD.log
LAUNCHAGENTS  = ~/Library/LaunchAgents/com.mssanwel.agent-pm.{dispatch,weekly}.plist
```

Rules:
- Never edit files outside `~/code/agent-pm/.claude/` from this command (except loading launchd plists).
- Any mutating command (`pause`, `resume`, `set`) must **show a diff and confirm** before writing, unless `--yes` is passed.

---

## status

Show current state of the dispatcher. No writes.

Collect in parallel where possible:

1. **Pause flag.** `test -f ~/code/agent-pm/.claude/agent-pm/pause.flag` — report `PAUSED` + first line of the file if present, else `LIVE`.
2. **Working hours.** Parse `CONFIG`. `TZ=<timezone> date +%H:%M` → compare against `working_hours.start|end|days`. Report in-window or out-of-window.
3. **launchd status.** `launchctl list | grep agent-pm` — confirm both jobs loaded, show last exit status.
4. **Last dispatch run.** Tail `~/code/agent-pm/.claude/agent-pm/logs/dispatch-$(date +%Y-%m-%d).log` — show the last 3 lines.
5. **Heartbeat (last run stats).** `tail -1 HEARTBEAT` — parse the JSON and show `ts`, `feedback/triage/worker` counts, `tokens`, `cost_usd`.
6. **Queue sizes** — three parallel `list_issues` calls on team Mssanwel (`c2b9eeef-df4b-4afd-884f-49a3fc78f8eb`):
   - `label=agent-pm, updatedAt >= now-15min` → feedback
   - `label=agent-pm, state=AI Todo` → triage
   - `label=agent-pm, state=AI In Progress` → worker
7. **Today's cost.** `grep $(date -u +%Y-%m-%d) HEARTBEAT | jq -s 'map(.cost_usd) | add'` — sum today's lines, compare to `cost_caps.daily_usd_stop`.
8. **Last 3 log entries.** Tail `LOG`.

Render as a compact status block.

---

## pause [reason]

1. Compose body: `paused: <ISO timestamp>\nreason: <reason or "manual">`
2. `Write ~/code/agent-pm/.claude/agent-pm/pause.flag` with that body
3. Confirm: "Paused. Dispatcher will exit on next tick without any LLM or Linear call."

## resume

1. `test -f ~/code/agent-pm/.claude/agent-pm/pause.flag` — if absent, say "Already live" and stop.
2. **If outside working hours**: confirm first. Show current time vs window, ask "Resume anyway?"
3. `Bash: rm ~/code/agent-pm/.claude/agent-pm/pause.flag`
4. Confirm: "Resumed. Next scheduled tick will run (within 10 min)."

Optional: offer to force an immediate run with `launchctl start com.mssanwel.agent-pm.dispatch`.

---

## config

Print `CONFIG` (`~/code/agent-pm/.claude/agent-pm/config.yaml`) with a one-line annotation next to each top-level key. No writes.

## set <path> <value>

Edit a single value in `config.yaml` using dotted path notation.

Examples:

```
/agent-pm set timezone Asia/Karachi
/agent-pm set working_hours.start 09:00
/agent-pm set working_hours.days [mon,tue,wed,thu,fri]
/agent-pm set limits.max_worker_items 2
/agent-pm set cost_caps.daily_usd_stop 50
/agent-pm set skill_overrides.crm-sync.working_hours.enabled false
/agent-pm set notify.slack_webhook "https://hooks.slack.com/services/..."
```

Steps:

1. Read the current value at `<path>` in `CONFIG`. If the path doesn't exist, say so and confirm creation.
2. Parse `<value>`: bools → `true`/`false`; integers stay; lists `[a,b,c]` → YAML sequence; strings → quoted if they contain spaces or colons.
3. Show a three-line diff:
   ```
   <path>:
     before: <old>
     after:  <new>
   ```
4. Ask to confirm (skip if `--yes` was passed).
5. On confirm, `Edit` the file in place (preserving surrounding comments).
6. **If the change affects scheduling** (`frequency.*`): remind the user to run `/agent-pm deploy` to reload launchd.

---

## skills

List all registered skills. Read `REGISTRY`. Render:

| Skill | Labels | Handler | Keywords | Approval | Last used |
|---|---|---|---:|---:|---|

"Last used" comes from the learning-log — most recent date a matching entry appears.

## test <skill-name> "<issue-title>"

Dry run router — no Linear writes.

1. Load `REGISTRY` and the last 20 entries from `LOG`.
2. Given `<issue-title>` (plus any description on subsequent lines), simulate Phase 3 triage:
   - Score keyword matches per skill
   - Note any label matches
   - Pick a winner
3. Print: `Matched: <skill>. Reason: <one-line>. Handler: <handler>. Approval: <bool>.`

Use to tune `keywords:` before shipping a change.

---

## log [n]

Tail the last N learning-log entries (default 10). Read `LOG`.

## deploy

Re-install the launchd jobs so cron changes in `config.yaml` (or changes to the plist files) take effect.

**Note:** `frequency.dispatch_cron` in `config.yaml` is informational only — the actual schedule is defined in the launchd plists at `~/code/agent-pm/scripts/launchd/`. If you changed either, run this.

Steps:

1. `Bash: ~/code/agent-pm/scripts/install-launchd.sh` — the installer is idempotent (unloads then reloads).
2. Verify: `launchctl list | grep agent-pm` — both jobs should be listed.
3. Optional sanity check: `launchctl start com.mssanwel.agent-pm.dispatch` — fires one immediate run. Tail the log to confirm.

To uninstall entirely: `Bash: ~/code/agent-pm/scripts/install-launchd.sh uninstall`.

---

## doctor

Health check. Read-only. Prints pass/fail per item with a remedy when something's wrong.

1. **Files present**: `CONFIG`, `REGISTRY`, `LOG`, `DISPATCH_TRIG`, `WEEKLY_TRIG`, both runner scripts executable.
2. **YAML parses**: `python3 -c "import yaml; yaml.safe_load(open('CONFIG'))"` and same for `REGISTRY`.
3. **Registry sanity**: `linear.team_id`, all state IDs, all label IDs are present and non-placeholder (no `TODO-create-` strings).
4. **Linear state IDs resolve**: for each state UUID, `get_issue_status`. Any failures flagged with their UUID.
5. **Linear labels resolve**: `list_issue_labels` + check each registry UUID is in the result set.
6. **Heartbeat file writable**: `test -w HEARTBEAT || touch HEARTBEAT`. If unwritable — big red alert.
7. **launchd**: `launchctl list | grep agent-pm` shows both jobs, last exit status 0 (or not-yet-run).
8. **Slash command reachable**: `test -L ~/.claude/commands/agent-pm.md` → is the symlink in place?
9. **Pause flag**: present / not present (status, not a pass/fail).
10. **Recent dispatch activity**: does `RUNNER_LOG` for today exist? Any errors in it?
11. **Claude CLI found**: `command -v claude` resolves.
12. **Today's cost vs cap**: show current spend from heartbeat, compare to `cost_caps.daily_usd_stop`.

Render as a grid:

```
✓ config.yaml parses
✓ skill-registry.yaml parses
✓ all state UUIDs resolve
✓ heartbeat.jsonl writable (last run 2026-04-16T05:57:40Z)
✓ launchd dispatch loaded (last exit 0)
⚠  pause.flag PRESENT — dispatcher is paused (this may be intentional)
✓ claude CLI at /opt/homebrew/bin/claude
✓ slash command symlink at ~/.claude/commands/agent-pm.md
✓ today's cost: $0.35 / cap $25.00
```
