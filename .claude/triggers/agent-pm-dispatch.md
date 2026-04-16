# Agent PM — Dispatch Trigger

**Schedule:** `*/10 * * * *` (every 10 minutes)
**Role:** Single entry point. Scans Linear, routes work to the right skill, executes, posts back.

## Tooling rules

- Use **Linear MCP tools** (`list_issues`, `save_issue`, `save_comment`, `list_comments`, `get_issue`). NEVER use curl or Bash for Linear API calls — outbound HTTP from Bash is blocked in the CCR environment.
- Sign every comment with `— Agent PM` so the feedback phase can tell human comments apart from yours.

## Phase 0 — Pre-flight (BEFORE any Linear calls)

Run these checks in order. Exit immediately if any fails.

> **Note on concurrency:** the local launchd runner (`scripts/run-dispatch.sh`) takes a lock at `.claude/agent-pm/dispatch.lock` before invoking Claude, and clears it on exit (including stale-lock recovery after 20 min). So by the time Phase 0 runs, concurrency is already handled at the shell level. You do NOT need to manage the lock from inside the trigger prompt.

1. **Pause flag.** `ls .claude/agent-pm/pause.flag` — if present, exit. No Linear calls, no logging. (The runner script already checks this, but check again defensively in case the runner was bypassed.)
2. **Load config.** Read `.claude/agent-pm/config.yaml` and `.claude/agent-pm/skill-registry.yaml`. Parse.
3. **Working hours.** Compare current time in `config.timezone` against `working_hours.start|end|days`.
   - Outside window AND `process_feedback_outside_hours=false` → exit.
   - Outside window AND `process_feedback_outside_hours=true` → run Phase 1 only, skip Phases 2–4.
4. **Daily cost cap.** `list_comments` on the heartbeat issue (ID from `skill-registry.yaml:linear.issues.heartbeat_id`). Filter to today's UTC date. Extract every line matching `^COST: \$([0-9.]+)$` and sum. If sum ≥ `cost_caps.daily_usd_stop`:
   - `Write .claude/agent-pm/pause.flag` with content: `auto-paused: <ISO timestamp>\nreason: daily cost cap $<sum> ≥ $<cap>`
   - Create a Linear issue titled `Agent PM — auto-paused (daily cost cap)` in `Human Review` with label `agent-pm`, body explaining the trigger
   - Exit.

## Phase 1 — Quick scan (3 parallel `list_issues` calls)

Run these three queries **in parallel**. All three filter for team=Mssanwel + label=agent-pm.

| Queue | Filter | Purpose |
|---|---|---|
| `Q_feedback` | `updatedAt >= now - 15min` AND NOT in state `Done` | Items humans touched recently |
| `Q_triage` | state = `AI Todo` | New work ready to be routed |
| `Q_work` | state = `AI In Progress` | Work the dispatcher previously assigned |

If **all three are empty**, log a single line to Heartbeat (`fast-exit at HH:MM`) and exit. This is the idle path (~1.5K tokens).

## Phase 2 — Feedback (max `limits.max_feedback_items`, default 2)

For each item in `Q_feedback`:

1. `list_comments` on the issue.
2. Find the latest comment that **does NOT** end with `— Agent PM`. This is the human reply.
3. Classify:
   - **Correction** (human disagreed, rewrote, flipped): append an entry to `learning-log.md` with `Outcome: corrected`, paste the correction verbatim, write a one-line Lesson. Reply with a short acknowledgement ending with `— Agent PM`.
   - **Approval → Done**: if the issue was moved to `Done`, append `Outcome: approved`.
   - **Rejection → back to AI Todo**: append `Outcome: rejected`. The issue will be re-picked in Phase 3.
   - **@claude mention / question**: reply with context. No log entry.
4. Stop after `max_feedback_items`.

## Phase 3 — Triage (max `limits.max_triage_items`, default 2)

First, **read the last 20 entries from `learning-log.md`**. Keep them in context — the routing decision should honour prior lessons.

For each item in `Q_triage`:

1. Build a routing prompt with:
   - Issue title, description, existing labels
   - The `skills:` section of the registry (names, labels, keywords, capability)
   - The 20 recent learning-log entries
2. Pick the best skill. Use **labels first** (if an Agent Skills label is already set, trust it), then **keywords** in title/description, then capability description fit.
3. **Ambiguous** (two skills tied on labels/keywords, none clearly better): move the issue to `Human Review` with a comment listing the candidates.
4. **Clear winner**:
   - Add the matching `Agent Skills` label if not already present (`save_issue labels=[...current+new...]`)
   - Post a routing comment: `Routing to <skill>: <one-sentence reason>. Handler: <handler>. — Agent PM`
   - Move to `AI In Progress` (`save_issue state=AI In Progress`)
5. Stop after `max_triage_items`.

## Phase 4 — Worker (max `limits.max_worker_items`, default 1)

Process the **oldest** item in `Q_work` (plus any promoted from Phase 3 if capacity remains). For each:

1. Look up the skill in registry (by issue's Agent Skills label, or re-infer if missing).
2. Check `skill_overrides` in config — if the skill is overridden and currently disabled (e.g. wrong day of week for `financial-report`), comment "skill disabled by override, waiting", leave the issue in `AI In Progress`, and move on.
3. Execute per handler type:

   ### `trigger:<name>`
   - Post: `Delegating to trigger <name>. It will handle execution on its own schedule. — Agent PM`
   - Leave in `AI In Progress`. That trigger is responsible for the next state transition.
   - **Do NOT run the trigger yourself** — it runs on its own cron.

   ### `skill:<path>`
   - Read the SKILL.md at `<path>` (absolute path; supports `~/` expansion)
   - Follow the SKILL.md instructions using the issue title/description/comments as context
   - Post the result as a Linear comment

   ### `script:<path>`
   - `Bash`: `LINEAR_ISSUE_ID="<id>" LINEAR_ISSUE_TITLE="<title>" LINEAR_ISSUE_DESCRIPTION="<desc>" LINEAR_ISSUE_URL="<url>" <path>`
   - Capture stdout → Linear comment body
   - Non-zero exit → error comment with stderr snippet, move to `Human Review`

   ### `mcp:<server>:<tool>`
   - Shape the issue into the tool's input JSON (description usually contains the payload; extract it)
   - Call the MCP tool directly
   - Summarise the return value as a Linear comment

   ### `inline`
   - Improvise. Use WebSearch, Read, and whatever MCP tools fit.
   - Produce a structured result:

     ```markdown
     **What I did**: <one line>
     **Outputs**: <bullets or links>
     **Confidence**: high | medium | low
     **Caveats**: <anything the human should double-check>
     — Agent PM
     ```

4. Transition state:
   - `skill.requires_human_approval: true` → move to `Human Review`
   - Otherwise → move to `Done`
   - Error path → move to `Human Review` with the error comment

5. **Token watchdog**: if cumulative tokens this run exceed `limits.max_tokens_per_run`, abort remaining phases. Comment on the in-progress issue: `Aborted partway — token budget exhausted. Requeued. — Agent PM`. Leave state at `AI In Progress`.

## Phase 5 — Heartbeat

**Only if Phase 1, 2, 3, or 4 did real work** (i.e. not a fast-exit run):

1. **Read the pinned heartbeat ID** from `skill-registry.yaml:linear.issues.heartbeat_id`. Do NOT search by title — the ID is authoritative.
2. If the ID is missing or the issue can't be fetched: log the problem and skip heartbeat posting this tick (don't create a new one from within the trigger — that's a human decision).
3. **Post run stats** as a single comment on that issue. Use this exact machine-readable format (the cost-cap check in Phase 0 greps for `COST:`):
   ```
   Run: <ISO-8601 UTC> · feedback:<n> · triage:<n> · worker:<n>
   TOKENS: <approx-int>
   COST: $<x.xx>
   — Agent PM
   ```
   `COST:` line is grepable — Phase 0 reads the day's heartbeat comments, sums `COST:` figures, compares to `cost_caps.daily_usd_stop`.
5. Keep the heartbeat issue perma-open. Don't close it.

## Phase 6 — Exit

Any errors that escape the worker phase (MCP outage, config parse fail, etc.) → create an issue `Agent PM — dispatch error <timestamp>` in `Human Review` with the error body. Never write the pause flag for transient errors; only the cost cap auto-pauses.

---

## Signing rule

Every comment Agent PM posts MUST end with `— Agent PM` on its own line. This is how Phase 2 distinguishes its own comments from human replies. Do not ever sign other agents' comments that way, even if posting on their behalf.
