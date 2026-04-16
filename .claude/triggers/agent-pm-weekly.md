# Agent PM — Weekly Consolidation Trigger

**Schedule:** `0 9 * * 1` (Monday 9am in `config.timezone`)
**Role:** Read the week's learning log, group corrections, auto-update the skill registry, post an observability report to Linear.

## Tooling rules

- Use **Linear MCP tools** only for Linear reads/writes.
- Edit `skill-registry.yaml` directly via the Edit tool. This trigger is the **only** automated writer to that file besides humans.
- Sign the Linear issue's body with `— Agent PM (weekly)`.

## Steps

### 1. Read the week's log

Read `.claude/agent-pm/learning-log.md`. Keep only entries dated within the last 7 days (inclusive of today).

### 2. Group and score

Group entries by skill name. For each skill, count:
- `approved` (success signals)
- `corrected` (human edited / commented a fix)
- `rejected` (human moved back to AI Todo)

Override rate = `(corrected + rejected) / total` per skill.

### 3. Find recurring patterns

Within each skill's entries, cluster corrections by theme (keyword overlap across the `Correction` and `Lesson` fields). If a theme appears **≥2 times**, it's a recurring pattern — a candidate for a registry change.

### 4. Apply registry changes

For each recurring pattern, decide an edit:

| Pattern | Registry action |
|---|---|
| Human kept asking "don't post yet, let me review" | Flip `requires_human_approval: true` on the skill |
| Human kept re-labelling the issue to a different skill | Move the problematic keyword from current skill to the correct one |
| Human kept adding missing context before re-running | Tighten the `capability:` sentence to spell out the prerequisite |
| Human kept saying "this should have gone to X" | Add X's canonical keywords to its `keywords` list |

Make the edit with the Edit tool. Keep diffs small and targeted.

### 5. Age out old entries

Move entries **older than 30 days** from `learning-log.md` to `learning-log-archive.md` (create the archive file if missing). Keep the original chronological order.

### 6. Post the weekly report

Create a Linear issue in the Mssanwel team:

- **Title**: `Agent PM — week of <YYYY-MM-DD of Monday>`
- **Labels**: `agent-pm`, `ops`, `report`
- **State**: `Done` (it's a record, not work to do)
- **Body** (markdown):

```markdown
## Summary

- Tasks handled: <total>
- Approved: <n> · Corrected: <n> · Rejected: <n>
- Override rate: <pct>%

## Skill usage

| Skill | Runs | Approved | Corrected | Rejected | Override rate |
|---|---:|---:|---:|---:|---:|
| <skill> | … | … | … | … | … |

## Top recurring corrections

1. **<theme>** — seen <n> times. Applied change: <diff summary>.
2. …

## Registry changes applied this week

- <file>:<key> — <before> → <after>

## Recommendations (not auto-applied)

- <anything that needs human judgment>

— Agent PM (weekly)
```

### 7. Exit

No heartbeat update — the weekly issue is itself the receipt.
