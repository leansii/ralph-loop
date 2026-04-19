# Ralph Loop

Autonomous Claude Code iteration loop with multi-agent review gate.

## What it does

Ralph Loop automates the implement-review-fix cycle for task-driven development:

1. **Implement** — reads `tasks.md`, picks the first unchecked task, builds it
2. **Review** — 4 parallel reviewers (code, design, styles, analyst) audit the commit
3. **Fix** — if reviewers find CRITICAL/HIGH issues, re-implements with feedback
4. **Mark done** — checks off the task, logs cost/tokens, moves to next

## Files

| File | Purpose |
|------|---------|
| `ralph-loop.sh` | Main script |
| `.env.example` | Configuration template |
| `.env` | Local overrides (gitignored) |

## Project structure expected

The target project needs:

```
project/
  tasks.md          # Task list with [ ] checkboxes
  CLAUDE.md         # Conventions / spec file
  .ralph/           # Created automatically
    progress.md     # Iteration log (append-only)
    cost-log.jsonl  # Per-task cost tracking
    state.json      # Resume state (ephemeral)
    review-deltas.md # Review findings (ephemeral)
```

## Do not

- Modify the review prompts without testing — they're tuned for structured output parsing
- Change the `sanitize_review_output` function — it strips non-conforming lines
- Remove `accum_cost` calls — they feed the cost tracking system
