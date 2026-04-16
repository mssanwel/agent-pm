# Architecture

## The one-pager

Agent PM is three things:

1. **A routing brain** (`skill-registry.yaml`) — maps Linear labels + keywords to handlers.
2. **A dispatcher** (`agent-pm-dispatch.md`) — single scheduled trigger that runs every 10 min. Pre-flight → scan → feedback → triage → worker.
3. **A learning loop** (`learning-log.md` + weekly trigger) — writes when you correct, reads during triage, auto-edits the registry weekly.

Linear is the UI and the message bus. Workflow states are a state machine. Comments are the conversation.

## Flow diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Linear (Mssanwel team)                    │
│  Backlog │ Todo │ AI Todo │ AI In Progress │ AI Review │ Human │ Done│
└────┬─────────────┬───────────────────────┬────────────────────┬─────┘
     │             │                       │                    │
     │             ▼                       │                    │
     │     (agent never touches)           │                    │
     │             ┌────────────┐          │                    │
     └────────────▶│  DISPATCH  │◀─────────┘                    │
                   │ every 10m  │                               │
                   └─────┬──────┘                               │
                         │                                      │
          ┌──────────────┼──────────────┬────────────┐          │
          ▼              ▼              ▼            ▼          │
     ┌────────┐     ┌─────────┐    ┌────────┐   ┌──────┐        │
     │Phase 0 │     │Phase 1  │    │Phase 2 │   │Phase3│        │
     │Preflt  │     │Feedback │    │Triage  │   │Worker│────────┘
     └───┬────┘     └────┬────┘    └───┬────┘   └──┬───┘
         │               │             │           │
       exit?           writes        reads        executes
      pause?           to log       from log      via handler
      hours?                         + reg        └─────┐
      cost?                                             ▼
                                                ┌───────────────┐
                                                │   Handler     │
                                                │  trigger: …   │
                                                │  skill: …     │
                                                │  script: …    │
                                                │  mcp: …       │
                                                │  inline       │
                                                └───────────────┘
```

## State machine

| From | Trigger | To |
|---|---|---|
| `AI Todo` | triage matched a skill | `AI In Progress` |
| `AI Todo` | ambiguous — no clear match | `Human Review` |
| `AI In Progress` | worker executed, needs review | `Human Review` |
| `AI In Progress` | worker executed, no approval needed | `Done` |
| `AI In Progress` | handler = `trigger:X` | stays (delegated trigger takes over) |
| `Human Review` | user moves back to `AI Todo` | re-queued (correction written to log) |
| `Done` | feedback phase detects | success entry written to log |

## Handler semantics

### `trigger:<name>`

Post a comment (`Delegating to trigger <name>`), leave the issue in `AI In Progress`. The named scheduled trigger picks it up on its own schedule and handles state transitions. Used for existing bespoke pipelines like `crm-sync-analysis`.

### `skill:<path>`

Read the SKILL.md at `<path>` (absolute path, can be inside `~/.claude/skills/` or inside this repo). Claude follows the SKILL.md instructions with the issue context. Result posted as a comment.

### `script:<path>`

Bash invocation. Env vars: `LINEAR_ISSUE_ID`, `LINEAR_ISSUE_TITLE`, `LINEAR_ISSUE_DESCRIPTION`, `LINEAR_ISSUE_URL`. stdout → Linear comment body. Non-zero exit → error comment + `Human Review`.

### `mcp:<server>:<tool>`

Direct MCP tool call. Dispatcher shapes issue context into the tool's input JSON by reading the description (Claude makes the judgment call). Used for one-step writes like "create Obsidian note" or "ingest into Graphify".

### `inline`

Claude improvises — WebSearch, Read, MCP tools, whatever helps. Produces a structured result (what / outputs / confidence / caveats). Fallback when nothing better fits.

## Learning loop details

### Write path

Feedback phase scans `label:agent-pm AND updatedAt >= now-15min`. For each issue:

- Latest comment from a human (not signed `— Agent PM`) containing correction language → append `corrected` entry.
- Moved to `Done` with no complaint → append `approved` entry.
- Moved back to `AI Todo` → append `rejected` entry with context.

### Read path

Triage phase reads the last 20 entries of `learning-log.md` before matching. Prior lessons for this skill or this kind of task feed into the routing decision.

### Consolidation path

Weekly trigger groups entries by skill. Recurring corrections (≥2 occurrences) become registry edits:

- "Always ask before posting a draft email" → flip `requires_human_approval: true` for `content-draft`
- "'finance' should never go to research" → move the `finance` keyword from `research` to `financial-report`

## Cost model

| Phase | Est. tokens | Notes |
|---|---|---|
| Fast-exit | ~1.5K | 3 `list_issues` + exit |
| Feedback item | 3–5K | `list_comments` + reply |
| Triage item | 3–5K | issue + registry + log slice |
| Worker item | 10–50K | handler-dependent |
| Idle day (144 × fast-exit) | ~$2.90 | |
| Moderate day (5–10 tasks) | ~$3–8 | |

Daily cap in `config.yaml` auto-pauses the system when exceeded.
