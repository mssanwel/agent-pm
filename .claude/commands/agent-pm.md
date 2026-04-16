# /agent-pm — Control surface

Interactive control for the Agent PM dispatcher. Invoke with `/agent-pm <subcommand> [args]`.
Running `/agent-pm` with no args prints this help.

Claude reads this file and executes the branch that matches the subcommand. No separate code.

## Conventions

- Project root is the repo containing `.claude/agent-pm/`. Resolve all paths relative to it.
- Never edit any file outside `.claude/agent-pm/` or `.claude/commands/` from this command.
- Any command that mutates state (`pause`, `resume`, `set`) must **show a diff and confirm** before writing, unless `--yes` is passed.

---

## status

Show current state of the dispatcher. No writes.

Collect in parallel where possible:

1. **Pause flag.** Check `.claude/agent-pm/pause.flag` — report `PAUSED` + first line of the file if present, else `LIVE`.
2. **Working hours.** Parse `.claude/agent-pm/config.yaml`. Compute current time in `timezone`, report in-window or out-of-window.
3. **Last dispatch run.** `list_comments` on the Heartbeat issue (filter `labels=agent-pm,ops`, title `Agent PM — Heartbeat`); show the most recent run line.
4. **Queue sizes.** Three `list_issues` calls in parallel on team Mssanwel (`c2b9eeef-df4b-4afd-884f-49a3fc78f8eb`):
   - `label=agent-pm, updatedAt >= now-15min` — feedback queue
   - `label=agent-pm, state=AI Todo` — triage queue
   - `label=agent-pm, state=AI In Progress` — worker queue
5. **Cost.** Sum today's run costs from the Heartbeat comments. Compare to `cost_caps.daily_usd_stop`.
6. **Last 3 log entries.** Tail `.claude/agent-pm/learning-log.md`.

Render as a compact status table.

---

## pause [reason]

1. Compose a pause.flag body: `paused: <timestamp>\nreason: <reason or "manual">`
2. `Write` `.claude/agent-pm/pause.flag`
3. Confirm: "Paused. Dispatcher will exit on next tick."

## resume

1. Check `.claude/agent-pm/pause.flag` exists. If not, say "Already live" and stop.
2. **If outside working hours**: confirm first. Show current time vs window and ask "Resume anyway?"
3. Delete the flag via `Bash: rm .claude/agent-pm/pause.flag`
4. Confirm: "Resumed. Next tick will run."

---

## config

Print `.claude/agent-pm/config.yaml` with a short one-line explanation next to each top-level key. No writes.

## set <path> <value>

Edit a single value in `config.yaml` using dotted path notation.

Examples:
- `set working_hours.start 09:00`
- `set working_hours.days [mon,tue,wed,thu,fri]`
- `set limits.max_worker_items 2`
- `set frequency.dispatch_cron "*/5 * * * *"`
- `set cost_caps.daily_usd_stop 50`
- `set skill_overrides.crm-sync.working_hours.enabled false`

Steps:
1. Read current value at `<path>`. If not found, create the path.
2. Parse `<value>`: bools → `true`/`false`; lists `[a,b,c]` → YAML sequence; strings → quoted if they contain spaces or colons.
3. Show diff (before → after) and ask to confirm.
4. On confirm, `Edit` the file.
5. Remind: "If you changed `frequency.*`, run `/agent-pm deploy` to re-register the cron."

---

## skills

List all registered skills. Read `.claude/agent-pm/skill-registry.yaml`. For each entry under `skills:`, render:

| Skill | Labels | Handler | Keywords | Approval? | Last used |
|---|---|---|---:|---|---|

"Last used" comes from the learning-log (most recent date a matching entry appears).

## test <skill-name> "<issue-title>"

Dry run router. No Linear writes.

1. Load `skill-registry.yaml` and last 20 learning-log entries.
2. Given `<issue-title>` (and any additional description on subsequent lines), simulate Phase 3 triage:
   - Show keyword matches per skill
   - Show label matches
   - Pick a winner
3. Print: `Matched: <skill>. Reason: <one-line>. Handler: <handler>.`

Use this to tune keywords before committing.

---

## log [n]

Tail the last N learning-log entries (default 10). Read `.claude/agent-pm/learning-log.md`.

## deploy

Re-register the cron jobs. Reads `frequency.dispatch_cron` and `frequency.weekly_cron` from config.

1. `CronList` — inventory current Agent PM crons.
2. For each of dispatch / weekly:
   - If a cron with the matching label exists with a different schedule: `CronDelete` then `CronCreate` with the new schedule.
   - If missing: `CronCreate`.
3. Show the final `CronList` result.

Use this after changing `frequency.*` values.

---

## doctor

Health check. No writes. Prints pass/fail per item.

1. **Files present**: `config.yaml`, `skill-registry.yaml`, `learning-log.md`, `agent-pm-dispatch.md`, `agent-pm-weekly.md`.
2. **YAML parses**: config and registry.
3. **Linear state IDs resolvable**: for each state UUID in the registry, call `get_issue_status`. Flag any `TODO-create-` placeholders loudly.
4. **Linear label IDs**: same — `get_issue_status` / verify via `list_issue_labels`.
5. **MCP connectivity**: ping Linear (`list_teams`), Obsidian (trivial read), Graphify (if in registry as `mcp:`).
6. **Pause flag**: present / not present.
7. **Last dispatch success**: look for the latest Heartbeat comment without an error line.
8. **Today's cost vs cap**: compare.
9. **Cron registered**: `CronList` must contain both dispatch + weekly.

Print a grid. Red if any fail, with a suggested remedy for each.
