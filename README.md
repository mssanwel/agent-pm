# Agent PM

A Linear-native AI project manager. Drop an issue into an `AI Todo` column; Agent PM routes it to the right skill, executes it, posts the result back, and learns from your corrections. One dispatcher, many skills.

## What it actually does

- Polls your Linear board every 10 minutes
- For each `agent-pm` labelled issue in `AI Todo`, picks the best skill based on title, description, and label
- Executes the skill — which can be an **existing scheduled trigger**, a **SKILL.md file**, a **write script**, a **direct MCP call**, or **inline Claude improvisation**
- Posts the structured result as a Linear comment and moves the issue to `Human Review` or `Done`
- When you correct it, appends a lesson to a learning log
- Weekly, consolidates corrections and **edits its own skill registry** to stop making the same mistake

## Architecture

```
Linear (UI / message bus)
  │
  ▼
agent-pm-dispatch trigger (every 10 min)
  ├── Pre-flight: pause.flag? working hours? cost cap?
  ├── Phase 1: Feedback   (human corrections → learning log)
  ├── Phase 2: Triage     (AI Todo → routed to skill)
  └── Phase 3: Worker     (execute via handler, post result)
        │
        ├── trigger: delegate to existing scheduled trigger
        ├── skill:   read SKILL.md and follow it
        ├── script:  call a local script with issue context as env
        ├── mcp:     direct MCP tool call
        └── inline:  Claude improvises with WebSearch + MCP
```

Separate weekly trigger runs Mondays 9am to consolidate the learning log and update the registry.

## Quickstart

1. Clone this repo.
2. Install the Linear MCP in Claude Code (`claude mcp add linear …`).
3. Create the `AI Todo` state on your team, plus the `agent-pm` label and the `Agent Skills` label group. See `.claude/agent-pm/README.md` for the one-time setup commands.
4. Paste the resulting state/label IDs into `.claude/agent-pm/skill-registry.yaml`.
5. Point skills at your actual handlers — existing triggers, SKILL.md paths, scripts. The discovery step in the plan file shows how.
6. Register the cron via `CronCreate` or `/agent-pm deploy`. Dispatch on `*/10 * * * *`, weekly on `0 9 * * 1`.
7. Delete `.claude/agent-pm/pause.flag` to go live.

## Pause and resume

```
touch .claude/agent-pm/pause.flag       # pause
rm .claude/agent-pm/pause.flag          # resume
# or use the slash command
/agent-pm pause "reason"
/agent-pm resume
```

Dispatch exits on the first pre-flight check if the flag is present. Same goes for the auto-pause on daily cost cap.

## Adding a skill

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Files

| File | Purpose |
|---|---|
| `.claude/agent-pm/config.yaml` | Runtime settings (hours, caps, cron, model) |
| `.claude/agent-pm/skill-registry.yaml` | Label/keyword → handler map + Linear IDs |
| `.claude/agent-pm/learning-log.md` | Rolling log of corrections (read during triage) |
| `.claude/agent-pm/pause.flag` | Kill switch — present = paused |
| `.claude/triggers/agent-pm-dispatch.md` | Every-10-min dispatcher |
| `.claude/triggers/agent-pm-weekly.md` | Monday consolidation + report |
| `.claude/commands/agent-pm.md` | `/agent-pm` slash command |

## License

MIT. See [LICENSE](LICENSE).
