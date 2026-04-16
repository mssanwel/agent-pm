# Contributing — Agent PM

Add a new capability without touching the dispatcher. The registry decouples routing from execution.

## Add a skill in 4 steps

1. **Decide the handler type.** One of:

   | Handler | When to use |
   |---|---|
   | `trigger:<name>` | A scheduled trigger already does this work — delegate. |
   | `skill:<path>` | A `SKILL.md` file exists — in this repo or in `~/.claude/skills/`. |
   | `script:<path>` | A working Python/TS/bash script does the work — wrap it. |
   | `mcp:<server>:<tool>` | Direct MCP tool call (e.g. Obsidian, Graphify). |
   | `inline` | Claude improvises with WebSearch + MCP — fallback only. |

2. **Add an entry to `.claude/agent-pm/skill-registry.yaml`:**

   ```yaml
   my-new-skill:
     labels: [my-label]               # Linear labels that route to this skill
     keywords: [keyword, another]     # title/description keywords for disambiguation
     handler: skill:path/to/SKILL.md
     capability: "Short sentence of what it does"
     requires_human_approval: false   # true → Human Review; false → Done
   ```

3. **Create the Linear label** if it's new (via Linear UI or MCP `create_issue_label`). Record the ID in the registry header.

4. **Test with a dry-run.** Create a Linear issue with the trigger phrase, label `agent-pm`, and state `AI Todo`. Next dispatch tick picks it up. Watch the comment stream.

## Handler contract

All handlers receive this context:

- `issue.id` — Linear issue ID (e.g. `MSS-123`)
- `issue.title` — title
- `issue.description` — body
- `issue.comments` — prior comments on the issue

**Scripts** receive it as env vars: `LINEAR_ISSUE_ID`, `LINEAR_ISSUE_TITLE`, `LINEAR_ISSUE_DESCRIPTION`. stdout becomes the Linear comment. Non-zero exit → error path.

**MCP calls** receive the issue context shaped into the tool's expected input by the dispatcher.

## Learning loop

When you correct agent output by commenting or editing the issue:

- The next dispatch picks up the change via `updatedAt` scan
- Writes a lesson to `.claude/agent-pm/learning-log.md`
- Triage phase reads the last 20 log entries before routing — so the lesson applies immediately

Weekly trigger groups recurring corrections and auto-edits the registry (e.g. adds a keyword, flips `requires_human_approval`).

## Pause / kill switch

Before doing anything risky, verify:

```
ls .claude/agent-pm/pause.flag
```

If present, dispatch exits immediately. Create it to pause:

```
touch .claude/agent-pm/pause.flag
```

Or use `/agent-pm pause "reason"`.

## Don't duplicate — delegate

If a skill already exists in `~/.claude/skills/` or as a scheduled trigger, **reference it**, don't rewrite. The registry is a routing table; the skill ecosystem is the engine.
