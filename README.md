# Ralph Loop

Autonomous task execution loop for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Implements tasks from a checklist, runs multi-agent review, fixes issues, and tracks costs — all unattended.

## Flow

```
┌─────────────┐    ┌──────────────────┐    ┌─────────────┐
│  IMPLEMENT   │───▶│   REVIEW GATE    │───▶│  MARK DONE  │
│  (sonnet)    │    │  4x parallel:    │    │  + cost log  │
│              │    │  code / design   │    │             │
│  Read task   │    │  styles / analyst │    │  Next task  │
│  Build it    │◀───│                  │    └─────────────┘
│  Commit      │    │  CRITICAL/HIGH?  │
└─────────────┘    │  → re-implement  │
                   └──────────────────┘
```

## Quick start

### Option A: Install inside your project

```bash
# Copy into your project
mkdir -p .ralph
cp ralph-loop.sh .ralph/
cp .env.example .ralph/.env

# Create required files
echo "# Tasks" > tasks.md
echo "# Progress" > .ralph/progress.md

# Run
.ralph/ralph-loop.sh
```

### Option B: Run from anywhere

```bash
# Point to your project
./ralph-loop.sh /path/to/project

# Or set PROJECT_ROOT
PROJECT_ROOT=/path/to/project ./ralph-loop.sh
```

## Configuration

Copy `.env.example` to `.env` (next to `ralph-loop.sh`) and adjust:

```bash
# Models
MODEL_IMPLEMENT=sonnet      # or opus for complex tasks
MODEL_REVIEW=sonnet
FALLBACK_MODEL=haiku        # auto-fallback on overload

# Limits
MAX_ITERATIONS=50
MAX_REVIEW_ROUNDS=3         # review cycles before force-accept
MAX_BUDGET_USD=10.00        # stop when spending exceeds this

# Review
PARALLEL_REVIEWS=true       # false = sequential (safer for low rate limits)

# Project files
TASKS_FILE=tasks.md
SPEC_FILE=CLAUDE.md         # or SPEC.md, any conventions file
```

## Task file format

```markdown
# My Project Tasks

- [ ] **1.1 — Create user model**
  Description of what to build...

- [ ] **1.2 — Add validation**
  Must validate email format...

- [x] **1.3 — Already done**
  This was completed earlier.
```

Ralph picks the first `- [ ]` task, implements it, reviews, marks `[x]`, moves on.

## Cost tracking

Every completed task logs to `.ralph/cost-log.jsonl`:

```json
{
  "task_id": "1.1",
  "task": "Create user model",
  "implement": { "cost_usd": 0.14, "input_tokens": 45000, "output_tokens": 12000 },
  "review": { "cost_usd": 0.08, "input_tokens": 32000, "output_tokens": 4000 },
  "total": { "cost_usd": 0.22, "api_calls": 6, "review_rounds": 1 }
}
```

Console output after each task:
```
[$] Task 1.1: impl=$0.14 (45K in/12K out) | review=$0.08 (32K in/4K out) | total=$0.22 | 6 calls
```

## Rate limit handling

| Error | Detection | Behavior |
|-------|-----------|----------|
| 429 rate limit | `rate_limit`, `too many requests` | Wait 60s, exponential backoff |
| 529 overloaded | `overloaded`, `capacity` | Wait 30s, exponential backoff |
| Usage cap | `hit your limit`, `quota exceeded` | Parse reset time from message, sleep until then |
| Unknown | Anything else | Wait 60s, exponential backoff |

When the error says "resets 9pm", ralph parses the time and sleeps exactly until 9:01pm instead of retrying blindly.

## Resume after interruption

State is saved to `.ralph/state.json` on every phase transition. If interrupted (Ctrl+C, crash, rate limit), just re-run — it picks up where it left off.

```bash
# Interrupted during review of task 3.2
# Just re-run:
.ralph/ralph-loop.sh
# → "Resuming from iteration 15, phase: review_code, review round: 2"
```

## Review agents

4 specialized reviewers run after each implementation:

| Reviewer | Focus |
|----------|-------|
| **Code** | Bugs, logic errors, missing error handling, TypeScript issues |
| **Design** | Component structure, props/emits, Vue conventions |
| **Styles** | Design token compliance, pixel-perfect styling |
| **Analyst** | Spec compliance, missing requirements, scope creep |

Only **CRITICAL** and **HIGH** findings trigger re-implementation. **LOW** findings are logged but don't block.

## Signals

- **Ctrl+C** — kills all child processes (including parallel reviewers), saves state, exits cleanly
- **Re-run** — auto-resumes from saved state
- **`rm .ralph/state.json`** — force fresh start (keeps progress and cost logs)
