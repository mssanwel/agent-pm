# .claude/agent-pm — Internal System Docs

Operational reference for people running or modifying the dispatcher. For high-level context, see the repo-root `README.md` and `docs/architecture.md`.

## Files in this directory

| File | Written by | Read by |
|---|---|---|
| `config.yaml` | humans / `/agent-pm set` | dispatch (Phase 0), weekly |
| `skill-registry.yaml` | humans, weekly trigger | dispatch (Phase 3, 4), `/agent-pm` |
| `learning-log.md` | dispatch (Phase 2) | dispatch (Phase 3), weekly, `/agent-pm log` |
| `learning-log-archive.md` | weekly (rotation) | read-only history |
| `pause.flag` | humans / `/agent-pm pause`, dispatch auto-pause | dispatch (Phase 0) |
| `README.md` | you | — |

## One-time setup (before first run)

1. **Create `AI Todo` state.** Linear MCP doesn't expose state creation, so do this in the Linear UI:
   - Settings → Mssanwel team → Workflow → Add status
   - Name: `AI Todo`
   - Type: `unstarted`
   - Position: immediately after `Todo`
   - Save, then copy its UUID from the URL or via the API
2. **Paste the UUID** into `skill-registry.yaml` under `linear.states.ai_todo`, replacing the `TODO-create-AI-Todo-state-in-Linear-UI` placeholder.
3. **Verify with `/agent-pm doctor`** — it flags unresolved placeholders.
4. **Register cron.** `/agent-pm deploy` — this creates the two scheduled triggers from `config.yaml`.
5. **Test paused.** With `pause.flag` still present, manually invoke the dispatch trigger (via `RemoteTrigger` or the trigger UI). It should exit cheaply in Phase 0.
6. **Go live.** `/agent-pm resume` (or `rm pause.flag`). Next tick runs.

## Adding a skill

See top-level `CONTRIBUTING.md`. In short:
- Add a block under `skills:` in `skill-registry.yaml`
- If it's a new label, create it in Linear and paste the ID into the `labels:` section
- Test via `/agent-pm test <skill-name> "<sample title>"` (dry run)

## Pausing

Three ways, all equivalent:
- `/agent-pm pause "reason"`
- `touch .claude/agent-pm/pause.flag`
- Auto: dispatcher writes the flag when daily cost cap is hit

Resume with `/agent-pm resume` or `rm .claude/agent-pm/pause.flag`.

## The learning loop

1. Agent PM does work and posts a comment.
2. Human edits the issue (comment / state move / label change).
3. Next tick: Phase 2 scans `updatedAt >= now-15min` and finds the change.
4. Phase 2 writes an entry to `learning-log.md` (see entry format at the top of that file).
5. Phase 3 reads the last 20 entries before matching. New lessons apply from the next tick.
6. Monday 9am: the weekly trigger groups recurring lessons and edits `skill-registry.yaml`.

The log is a normal markdown file. Edit it by hand to seed lessons or remove noise.

## What the dispatcher is allowed to write

- Linear issues (create, update, comment, move state) — only for the Mssanwel team, only on issues labelled `agent-pm`.
- `.claude/agent-pm/learning-log.md` — append only (during Phase 2).
- `.claude/agent-pm/pause.flag` — only for auto-pause on cost cap.
- Files the executed handler writes (e.g. Obsidian vault for `email-sync`). Those are the handler's responsibility, not the dispatcher's.

**Everything else is read-only.**

## When to tune what

| Symptom | Fix |
|---|---|
| Dispatcher too chatty (heartbeat spam) | Phase 5 already gates on "did work" — if still noisy, increase `min_seconds_between` in config |
| Wrong skill picked | Tune `keywords:` in the registry; or add a lesson to the learning-log |
| Agent keeps asking for approval | Flip `requires_human_approval: false` once you trust it |
| Agent shouldn't run weekends | `working_hours.days` already excludes sat/sun — confirm and/or tighten `process_feedback_outside_hours` |
| Cost creeping | Lower `limits.max_worker_items` to 1; raise `min_seconds_between.worker` |
