#!/bin/bash

# Ralph Loop v2 — autonomous Claude Code iteration with multi-agent review
#
# Flow per task:
#   1. IMPLEMENT (sonnet) — build the task
#   2. REVIEW GATE (parallel reviewers) — code, design, analyst
#   3. MERGE DELTAS — collect findings, update spec/tasks if needed
#   4. If deltas found → re-implement (up to MAX_REVIEW_ROUNDS)
#   5. If no deltas → mark done, next task
#
# Rate limit handling:
#   - Uses --output-format json for structured error parsing
#   - Classifies errors: rate_limit (429), overloaded (529), usage/quota cap
#   - Countdown timer with visual feedback during wait
#   - Persists resume_at timestamp for restart after crash/manual stop
#   - --fallback-model as first line of defense against overload

set -e

# Global cleanup: kill all child processes on exit/interrupt
RALPH_INTERRUPTED=false
cleanup() {
  RALPH_INTERRUPTED=true
  local children
  children=$(jobs -p 2>/dev/null)
  if [ -n "$children" ]; then
    kill $children 2>/dev/null || true
    wait $children 2>/dev/null || true
  fi
  pkill -P $$ 2>/dev/null || true
  printf "\n\033[33m[$(date +%H:%M:%S)] Interrupted. State saved — rerun to resume.\033[0m\n" 2>/dev/null || true
}
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# =============================================================================
# Configuration (defaults — override via .ralph/.env or environment variables)
# =============================================================================

# Resolve script location for .env loading
RALPH_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env if present (from same directory as script)
if [ -f "$RALPH_SCRIPT_DIR/.env" ]; then
  set -a
  source "$RALPH_SCRIPT_DIR/.env"
  set +a
fi

MAX_ITERATIONS="${MAX_ITERATIONS:-50}"
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-3}"
RATE_LIMIT_MAX_RETRIES="${RATE_LIMIT_MAX_RETRIES:-10}"
PARALLEL_REVIEWS="${PARALLEL_REVIEWS:-true}"

# Wait times by error type (seconds)
WAIT_RATE_LIMIT="${WAIT_RATE_LIMIT:-60}"
WAIT_OVERLOADED="${WAIT_OVERLOADED:-30}"
WAIT_USAGE_CAP="${WAIT_USAGE_CAP:-300}"
WAIT_MAX="${WAIT_MAX:-900}"
WAIT_EMPTY_RESPONSE="${WAIT_EMPTY_RESPONSE:-30}"

MODEL_IMPLEMENT="${MODEL_IMPLEMENT:-sonnet}"
MODEL_REVIEW="${MODEL_REVIEW:-sonnet}"
MODEL_MERGE="${MODEL_MERGE:-sonnet}"
FALLBACK_MODEL="${FALLBACK_MODEL:-haiku}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"

ALLOWED_TOOLS="${ALLOWED_TOOLS:-Read Write Edit Bash Grep Glob}"
STREAM_OUTPUT="${STREAM_OUTPUT:-true}"

# =============================================================================
# Path resolution
# =============================================================================

# When installed as a standalone tool: script is in the repo root
# When installed inside a project: script is in .ralph/ subdirectory
#
# Detect mode: if parent dir has tasks.md, we're inside .ralph/ of a project
# Otherwise we need PROJECT_ROOT passed as arg or via env

if [ -n "$PROJECT_ROOT" ]; then
  # Explicit PROJECT_ROOT from env
  cd "$PROJECT_ROOT"
elif [ -f "$(dirname "$RALPH_SCRIPT_DIR")/tasks.md" ]; then
  # Script is in .ralph/ subdirectory of a project
  PROJECT_ROOT="$(dirname "$RALPH_SCRIPT_DIR")"
  cd "$PROJECT_ROOT"
elif [ -f "$RALPH_SCRIPT_DIR/tasks.md" ]; then
  # Script is in the project root directly
  PROJECT_ROOT="$RALPH_SCRIPT_DIR"
  cd "$PROJECT_ROOT"
else
  # No project found — require first argument
  if [ -n "$1" ]; then
    PROJECT_ROOT="$(cd "$1" && pwd)"
    cd "$PROJECT_ROOT"
    shift
  else
    echo "Usage: ralph-loop.sh [PROJECT_ROOT]"
    echo ""
    echo "  Run from a project directory that contains tasks.md,"
    echo "  or pass the project path as the first argument."
    echo ""
    echo "  Example:"
    echo "    .ralph/ralph-loop.sh                # from project root"
    echo "    ~/tools/ralph-loop/ralph-loop.sh .   # explicit path"
    exit 1
  fi
fi

# Project files (relative to project root)
TASKS_FILE="${TASKS_FILE:-tasks.md}"
SPEC_FILE="${SPEC_FILE:-CLAUDE.md}"

# Ralph state directory (create if needed)
RALPH_STATE_DIR="${RALPH_STATE_DIR:-.ralph}"
mkdir -p "$RALPH_STATE_DIR"

# Ralph state files
PROGRESS_FILE="${PROGRESS_FILE:-$RALPH_STATE_DIR/progress.md}"
REVIEW_DELTAS_FILE="$RALPH_STATE_DIR/review-deltas.md"
LOOP_STATE_FILE="$RALPH_STATE_DIR/state.json"
COST_LOG_FILE="$RALPH_STATE_DIR/cost-log.jsonl"

# =============================================================================
# Dependencies
# =============================================================================

HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
fi

# JSON field extractor — uses jq if available, falls back to grep/sed
# Usage: json_get <json_string> <field_name>
# Returns: field value (unquoted string or number), empty string if not found
json_get() {
  local json="$1"
  local field="$2"

  if $HAS_JQ; then
    echo "$json" | jq -r ".$field // empty" 2>/dev/null || true
  else
    # Fallback: extract "field": "value" or "field": number
    local val
    val=$(echo "$json" | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"\(.*\)"/\1/')
    if [ -z "$val" ]; then
      # Try numeric value
      val=$(echo "$json" | grep -o "\"$field\"[[:space:]]*:[[:space:]]*[0-9][0-9.]*" | head -1 | sed 's/.*:[[:space:]]*//')
    fi
    echo "$val"
  fi
}

# JSON boolean check — returns 0 (true) if field is true
json_is_true() {
  local json="$1"
  local field="$2"

  if $HAS_JQ; then
    echo "$json" | jq -e ".$field == true" &>/dev/null
  else
    echo "$json" | grep -q "\"$field\"[[:space:]]*:[[:space:]]*true"
  fi
}

# Extract text result from claude --output-format json response
# The JSON has: { result: "text content", is_error: false, ... }
json_get_result() {
  local json="$1"

  if $HAS_JQ; then
    echo "$json" | jq -r '.result // empty' 2>/dev/null || true
  else
    # Result can be multiline — extract everything between "result": " and the closing "
    # This is fragile for complex content, but handles most cases
    echo "$json" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/p' | head -1
  fi
}

# =============================================================================
# Helpers
# =============================================================================

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log() {
  echo "[$(timestamp)] $1"
}

# ANSI color codes
C_DIM='\033[2m'
C_CYAN='\033[36m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_MAGENTA='\033[35m'
C_RESET='\033[0m'

# Pretty-print claude JSON result to stderr
# Extracts: model, cost, duration, turns, result text
format_claude_output() {
  local json="$1"
  if ! $HAS_JQ; then
    echo "$json" >&2
    return
  fi

  # Extract metadata
  local model duration cost turns result stop_reason
  model=$(echo "$json" | jq -r 'keys_unsorted as $k | .modelUsage // {} | keys[0] // "unknown"' 2>/dev/null)
  duration=$(echo "$json" | jq -r '.duration_ms // 0' 2>/dev/null)
  cost=$(echo "$json" | jq -r '.total_cost_usd // 0' 2>/dev/null)
  turns=$(echo "$json" | jq -r '.num_turns // 0' 2>/dev/null)
  stop_reason=$(echo "$json" | jq -r '.stop_reason // "unknown"' 2>/dev/null)
  result=$(echo "$json" | jq -r '.result // empty' 2>/dev/null)

  local duration_s
  duration_s=$(awk "BEGIN { printf \"%.1f\", $duration / 1000 }")

  # Print formatted header
  printf "\n${C_DIM}  ┌─ %s │ %ss │ $%s │ %s turns │ %s${C_RESET}\n" \
    "$model" "$duration_s" "$cost" "$turns" "$stop_reason" >&2

  # Print result text (truncated to 500 chars for log readability)
  if [ -n "$result" ]; then
    local truncated="$result"
    if [ ${#truncated} -gt 500 ]; then
      truncated="${truncated:0:500}..."
    fi
    echo "$truncated" | while IFS= read -r line; do
      printf "${C_DIM}  │${C_RESET} %s\n" "$line" >&2
    done
  fi

  printf "${C_DIM}  └──────────────────────────────────────${C_RESET}\n\n" >&2
}

# Countdown timer with visual feedback
# Usage: countdown_timer <seconds> <reason>
countdown_timer() {
  local wait_seconds=$1
  local reason="$2"
  local end_time=$(($(date +%s) + wait_seconds))

  while [ "$(date +%s)" -lt "$end_time" ]; do
    # Check if we were interrupted
    if $RALPH_INTERRUPTED; then
      printf "\n"
      return 1
    fi
    local remaining=$((end_time - $(date +%s)))
    if [ "$remaining" -lt 0 ]; then
      remaining=0
    fi
    local mins=$((remaining / 60))
    local secs=$((remaining % 60))
    printf "\r  [wait] %s | Resume in %02d:%02d " "$reason" "$mins" "$secs"
    sleep 1 || return 1  # sleep returns non-zero if interrupted by signal
  done

  printf "\r  [done] Wait complete, resuming...                              \n"
}

# Classify error type from claude JSON output
# Sets global: ERROR_TYPE (none|rate_limit|overloaded|usage_cap|unknown)
# Sets global: ERROR_WAIT (suggested wait in seconds)
classify_error() {
  local raw_output="$1"
  local exit_code="$2"

  ERROR_TYPE="none"
  ERROR_WAIT=0

  # If exit code is 0 and output looks like valid JSON with result, check is_error
  if json_is_true "$raw_output" "is_error"; then
    local error_text
    error_text=$(json_get_result "$raw_output")

    # Classify by error content
    if echo "$error_text" | grep -qi "rate.limit\|too many requests\|429"; then
      ERROR_TYPE="rate_limit"
      ERROR_WAIT=$WAIT_RATE_LIMIT
    elif echo "$error_text" | grep -qi "overloaded\|529\|capacity\|temporarily unavailable"; then
      ERROR_TYPE="overloaded"
      ERROR_WAIT=$WAIT_OVERLOADED
    elif echo "$error_text" | grep -qi "quota.exceeded\|usage.limit\|spending.limit\|budget\|monthly.*limit\|hit your limit\|hit.your.limit"; then
      ERROR_TYPE="usage_cap"
      ERROR_WAIT=$WAIT_USAGE_CAP
    else
      ERROR_TYPE="unknown"
      ERROR_WAIT=$WAIT_RATE_LIMIT
    fi

    # Try to extract retry-after hint from error text
    local retry_after
    retry_after=$(echo "$error_text" | grep -oi "retry.after[^0-9]*[0-9]*" | grep -o '[0-9]*' | tail -1)
    if [ -n "$retry_after" ] && [ "$retry_after" -gt 0 ] 2>/dev/null; then
      ERROR_WAIT=$retry_after
    fi

    # Try to extract "resets Xpm/Xam" or "resets HH:MM" from error text and compute wait
    local reset_time
    reset_time=$(echo "$error_text" | grep -oi "resets[^0-9]*[0-9]\{1,2\}[: ]\{0,1\}[0-9]*\s*[ap]m" | grep -oi "[0-9]\{1,2\}[: ]\{0,1\}[0-9]*\s*[ap]m" | tail -1)
    if [ -n "$reset_time" ]; then
      # Parse the reset time (e.g. "9pm", "9:00pm", "10am")
      local reset_hour reset_min ampm
      ampm=$(echo "$reset_time" | grep -oi "[ap]m")
      local time_part
      time_part=$(echo "$reset_time" | sed 's/[[:space:]]*[aApP][mM]//')
      if echo "$time_part" | grep -q ":"; then
        reset_hour=$(echo "$time_part" | cut -d: -f1)
        reset_min=$(echo "$time_part" | cut -d: -f2)
      else
        reset_hour="$time_part"
        reset_min=0
      fi
      # Convert to 24h
      if echo "$ampm" | grep -qi "pm" && [ "$reset_hour" -lt 12 ]; then
        reset_hour=$((reset_hour + 12))
      elif echo "$ampm" | grep -qi "am" && [ "$reset_hour" -eq 12 ]; then
        reset_hour=0
      fi
      # Compute seconds until reset
      local now_epoch reset_epoch
      now_epoch=$(date +%s)
      reset_epoch=$(date -j -f "%H:%M:%S" "${reset_hour}:${reset_min}:00" +%s 2>/dev/null || date -d "today ${reset_hour}:${reset_min}:00" +%s 2>/dev/null)
      if [ -n "$reset_epoch" ]; then
        # If reset time is in the past, assume tomorrow
        if [ "$reset_epoch" -le "$now_epoch" ]; then
          reset_epoch=$((reset_epoch + 86400))
        fi
        local wait_secs=$((reset_epoch - now_epoch + 60))  # +60s buffer
        if [ "$wait_secs" -gt 0 ] && [ "$wait_secs" -lt 86400 ]; then
          ERROR_WAIT=$wait_secs
          local wait_min=$((wait_secs / 60))
          printf "${C_YELLOW}  [info] Parsed reset time: %s → waiting %d minutes${C_RESET}\n" "$reset_time" "$wait_min"
        fi
      fi
    fi

    return
  fi

  # Not JSON or not is_error — check raw output for error signals (stderr mixed in)
  if echo "$raw_output" | grep -qi "rate.limit\|too many requests\|429"; then
    ERROR_TYPE="rate_limit"
    ERROR_WAIT=$WAIT_RATE_LIMIT
  elif echo "$raw_output" | grep -qi "overloaded\|529\|capacity"; then
    ERROR_TYPE="overloaded"
    ERROR_WAIT=$WAIT_OVERLOADED
  elif echo "$raw_output" | grep -qi "quota.exceeded\|usage.limit\|spending.limit\|hit your limit\|hit.your.limit"; then
    ERROR_TYPE="usage_cap"
    ERROR_WAIT=$WAIT_USAGE_CAP
  fi
}

# Run claude with structured error handling and retry logic
# Usage: run_claude <model> <prompt> [extra_args...]
# Returns: 0 on success, 1 on permanent failure
# Output is captured in $CLAUDE_OUTPUT (the text result, not raw JSON)
run_claude() {
  local model="$1"
  local prompt="$2"
  shift 2
  local extra_args=("$@")

  local retries=0
  local backoff_multiplier=1

  # Build claude command args
  local cmd_args=(
    --print
    --dangerously-skip-permissions
    --output-format json
    --allowedTools "$ALLOWED_TOOLS"
    --model "$model"
  )
  if [ -n "$FALLBACK_MODEL" ]; then
    cmd_args+=(--fallback-model "$FALLBACK_MODEL")
  fi
  if [ -n "$MAX_BUDGET_USD" ]; then
    cmd_args+=(--max-budget-usd "$MAX_BUDGET_USD")
  fi

  while [ $retries -lt $RATE_LIMIT_MAX_RETRIES ]; do
    local raw_output
    local cmd_exit=0
    raw_output=$(claude "${cmd_args[@]}" "${extra_args[@]}" "$prompt" 2>&1) || cmd_exit=$?
    if $STREAM_OUTPUT; then
      format_claude_output "$raw_output"
    fi

    # Classify the response
    classify_error "$raw_output" "$cmd_exit"

    case "$ERROR_TYPE" in
      none)
        # Success — extract the text result from JSON
        CLAUDE_OUTPUT=$(json_get_result "$raw_output")

        # Extract cost and token metrics for tracking
        if $HAS_JQ; then
          LAST_CALL_COST=$(echo "$raw_output" | jq -r '.total_cost_usd // 0' 2>/dev/null)
          LAST_CALL_INPUT_TOKENS=$(echo "$raw_output" | jq -r '[.modelUsage // {} | to_entries[] | .value.inputTokens // 0] | add // 0' 2>/dev/null)
          LAST_CALL_OUTPUT_TOKENS=$(echo "$raw_output" | jq -r '[.modelUsage // {} | to_entries[] | .value.outputTokens // 0] | add // 0' 2>/dev/null)
          LAST_CALL_DURATION=$(echo "$raw_output" | jq -r '.duration_ms // 0' 2>/dev/null)
        else
          LAST_CALL_COST=0
          LAST_CALL_INPUT_TOKENS=0
          LAST_CALL_OUTPUT_TOKENS=0
          LAST_CALL_DURATION=0
        fi

        # If JSON parsing failed, use raw output as fallback
        if [ -z "$CLAUDE_OUTPUT" ]; then
          CLAUDE_OUTPUT="$raw_output"
        fi

        # Still empty = genuine empty response
        if [ -z "$CLAUDE_OUTPUT" ]; then
          retries=$((retries + 1))
          local empty_wait=$((WAIT_EMPTY_RESPONSE * backoff_multiplier))
          if [ "$empty_wait" -gt "$WAIT_MAX" ]; then
            empty_wait=$WAIT_MAX
          fi
          log "EMPTY RESPONSE (attempt $retries/$RATE_LIMIT_MAX_RETRIES)"
          save_state "empty_response" "" "$(($(date +%s) + empty_wait))"
          countdown_timer "$empty_wait" "Empty response, retrying"
          backoff_multiplier=$((backoff_multiplier * 2))
          continue
        fi

        return 0
        ;;

      rate_limit)
        retries=$((retries + 1))
        local wait=$((ERROR_WAIT * backoff_multiplier))
        if [ "$wait" -gt "$WAIT_MAX" ]; then
          wait=$WAIT_MAX
        fi
        log "RATE LIMITED (attempt $retries/$RATE_LIMIT_MAX_RETRIES)"
        save_state "rate_limited" "" "$(($(date +%s) + wait))"
        countdown_timer "$wait" "Rate limited (429)"
        backoff_multiplier=$((backoff_multiplier * 2))
        ;;

      overloaded)
        retries=$((retries + 1))
        local wait=$((ERROR_WAIT * backoff_multiplier))
        if [ "$wait" -gt "$WAIT_MAX" ]; then
          wait=$WAIT_MAX
        fi
        log "SERVER OVERLOADED (attempt $retries/$RATE_LIMIT_MAX_RETRIES)"
        save_state "overloaded" "" "$(($(date +%s) + wait))"
        countdown_timer "$wait" "Server overloaded (529)"
        backoff_multiplier=$((backoff_multiplier * 2))
        ;;

      usage_cap)
        retries=$((retries + 1))
        local wait=$ERROR_WAIT
        # Usage caps don't benefit from short backoff — use the full wait
        log "USAGE CAP HIT (attempt $retries/$RATE_LIMIT_MAX_RETRIES)"
        log "This may be a monthly/daily spending limit. Wait time: ${wait}s"
        save_state "usage_cap" "" "$(($(date +%s) + wait))"
        countdown_timer "$wait" "Usage/spending limit reached"
        # Don't multiply backoff for usage caps — they have fixed reset windows
        ;;

      unknown)
        retries=$((retries + 1))
        local wait=$((ERROR_WAIT * backoff_multiplier))
        if [ "$wait" -gt "$WAIT_MAX" ]; then
          wait=$WAIT_MAX
        fi
        local error_preview
        error_preview=$(json_get_result "$raw_output" | head -c 200)
        log "UNKNOWN ERROR (attempt $retries/$RATE_LIMIT_MAX_RETRIES): $error_preview"
        save_state "unknown_error" "" "$(($(date +%s) + wait))"
        countdown_timer "$wait" "Unknown error, retrying"
        backoff_multiplier=$((backoff_multiplier * 2))
        ;;
    esac
  done

  log "ERROR: Max retries ($RATE_LIMIT_MAX_RETRIES) exceeded. Giving up on this step."
  return 1
}

# =============================================================================
# Cost & Token Tracking
# =============================================================================

# Per-call metrics (set by run_claude on success)
LAST_CALL_COST=0
LAST_CALL_INPUT_TOKENS=0
LAST_CALL_OUTPUT_TOKENS=0
LAST_CALL_DURATION=0

# Per-task accumulators (reset each iteration)
TASK_IMPL_COST=0
TASK_IMPL_INPUT=0
TASK_IMPL_OUTPUT=0
TASK_REVIEW_COST=0
TASK_REVIEW_INPUT=0
TASK_REVIEW_OUTPUT=0
TASK_TOTAL_CALLS=0

# Add last call metrics to a phase accumulator
# Usage: accum_cost <phase>  (phase: impl or review)
accum_cost() {
  local phase="$1"
  TASK_TOTAL_CALLS=$((TASK_TOTAL_CALLS + 1))
  if [ "$phase" = "impl" ]; then
    TASK_IMPL_COST=$(awk "BEGIN { printf \"%.6f\", $TASK_IMPL_COST + $LAST_CALL_COST }")
    TASK_IMPL_INPUT=$((TASK_IMPL_INPUT + LAST_CALL_INPUT_TOKENS))
    TASK_IMPL_OUTPUT=$((TASK_IMPL_OUTPUT + LAST_CALL_OUTPUT_TOKENS))
  else
    TASK_REVIEW_COST=$(awk "BEGIN { printf \"%.6f\", $TASK_REVIEW_COST + $LAST_CALL_COST }")
    TASK_REVIEW_INPUT=$((TASK_REVIEW_INPUT + LAST_CALL_INPUT_TOKENS))
    TASK_REVIEW_OUTPUT=$((TASK_REVIEW_OUTPUT + LAST_CALL_OUTPUT_TOKENS))
  fi
}

# Reset per-task accumulators
reset_task_cost() {
  TASK_IMPL_COST=0
  TASK_IMPL_INPUT=0
  TASK_IMPL_OUTPUT=0
  TASK_REVIEW_COST=0
  TASK_REVIEW_INPUT=0
  TASK_REVIEW_OUTPUT=0
  TASK_TOTAL_CALLS=0
}

# Write cost log entry for completed task
# Appends one JSON line to cost-log.jsonl
write_cost_log() {
  local task_id="$1"
  local task_desc="$2"
  local total_cost
  total_cost=$(awk "BEGIN { printf \"%.6f\", $TASK_IMPL_COST + $TASK_REVIEW_COST }")
  local total_input=$((TASK_IMPL_INPUT + TASK_REVIEW_INPUT))
  local total_output=$((TASK_IMPL_OUTPUT + TASK_REVIEW_OUTPUT))

  if $HAS_JQ; then
    jq -nc \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg task_id "$task_id" \
      --arg task_desc "$task_desc" \
      --argjson impl_cost "$TASK_IMPL_COST" \
      --argjson impl_input "$TASK_IMPL_INPUT" \
      --argjson impl_output "$TASK_IMPL_OUTPUT" \
      --argjson review_cost "$TASK_REVIEW_COST" \
      --argjson review_input "$TASK_REVIEW_INPUT" \
      --argjson review_output "$TASK_REVIEW_OUTPUT" \
      --argjson total_cost "$total_cost" \
      --argjson total_input "$total_input" \
      --argjson total_output "$total_output" \
      --argjson total_calls "$TASK_TOTAL_CALLS" \
      --argjson review_rounds "$REVIEW_ROUND" \
      '{
        timestamp: $ts,
        task_id: $task_id,
        task: $task_desc,
        implement: { cost_usd: $impl_cost, input_tokens: $impl_input, output_tokens: $impl_output },
        review: { cost_usd: $review_cost, input_tokens: $review_input, output_tokens: $review_output },
        total: { cost_usd: $total_cost, input_tokens: $total_input, output_tokens: $total_output, api_calls: $total_calls, review_rounds: $review_rounds }
      }' >> "$COST_LOG_FILE"
  else
    # Fallback without jq — simple format
    printf '{"timestamp":"%s","task_id":"%s","impl_cost":%s,"review_cost":%s,"total_cost":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task_id" "$TASK_IMPL_COST" "$TASK_REVIEW_COST" "$total_cost" >> "$COST_LOG_FILE"
  fi

  # Print summary to console
  printf "${C_YELLOW}  [$] Task %s: impl=$%s (%s in/%s out) │ review=$%s (%s in/%s out) │ total=$%s │ %s calls${C_RESET}\n" \
    "$task_id" "$TASK_IMPL_COST" "$TASK_IMPL_INPUT" "$TASK_IMPL_OUTPUT" \
    "$TASK_REVIEW_COST" "$TASK_REVIEW_INPUT" "$TASK_REVIEW_OUTPUT" \
    "$total_cost" "$TASK_TOTAL_CALLS" >&2
}

# =============================================================================
# State persistence (for resume after crash/manual stop)
# =============================================================================

# Save loop state for resume after crash/stop/rate-limit
# Usage: save_state <phase> [extra_info] [resume_at_unix_timestamp]
save_state() {
  local phase="$1"
  local extra="${2:-}"
  local resume_at="${3:-0}"

  cat > "$LOOP_STATE_FILE" << STATEEOF
{
  "iteration": $ITERATION,
  "task_id": "$CURRENT_TASK_ID",
  "phase": "$phase",
  "review_round": $REVIEW_ROUND,
  "timestamp": "$(timestamp)",
  "resume_at": $resume_at,
  "extra": "$extra"
}
STATEEOF
}

# Load state and handle pending wait time
# If resume_at is in the future, runs countdown for the remaining time
load_state() {
  if [ ! -f "$LOOP_STATE_FILE" ]; then
    return 1
  fi

  log "Found saved state, resuming..."

  local state
  state=$(cat "$LOOP_STATE_FILE")

  ITERATION=$(json_get "$state" "iteration")
  REVIEW_ROUND=$(json_get "$state" "review_round")
  local phase
  phase=$(json_get "$state" "phase")
  local resume_at
  resume_at=$(json_get "$state" "resume_at")

  RESUMED_PHASE="$phase"
  log "Resuming from iteration $ITERATION, phase: $phase, review round: $REVIEW_ROUND"

  # If we were waiting (rate limited, usage cap, etc.), check remaining time
  if [ -n "$resume_at" ] && [ "$resume_at" -gt 0 ] 2>/dev/null; then
    local now
    now=$(date +%s)
    local remaining=$((resume_at - now))

    if [ "$remaining" -gt 0 ]; then
      log "Was waiting during $phase. $remaining seconds remaining."
      countdown_timer "$remaining" "Resuming wait ($phase)"
    else
      log "Wait period already elapsed. Continuing immediately."
    fi
  fi

  return 0
}

clear_state() {
  rm -f "$LOOP_STATE_FILE"
}

# =============================================================================
# Phase: IMPLEMENT
# =============================================================================

do_implement() {
  printf "${C_GREEN}[$(timestamp)] IMPLEMENT: Starting task implementation...${C_RESET}\n"
  save_state "implement"

  local prompt="You are running in Ralph loop mode. Follow CLAUDE.md instructions exactly.

1. Read $TASKS_FILE — find the FIRST unchecked [ ] task
2. Read $SPEC_FILE for technical context on that task
3. Read $PROGRESS_FILE for learnings from previous iterations"

  # If we have review deltas, include them
  if [ -f "$REVIEW_DELTAS_FILE" ] && [ -s "$REVIEW_DELTAS_FILE" ]; then
    prompt="$prompt
4. Read $REVIEW_DELTAS_FILE — apply ALL review feedback before proceeding"
  fi

  prompt="$prompt

Then:
- Implement the task fully — working code, no stubs, no TODOs
- Run: npm run dev (verify no crash) — if it fails, fix it before proceeding
- Git commit: feat(workbench): <description>
- Append a brief entry to $PROGRESS_FILE: iteration number, task ID, files created/modified, any gotchas

IMPORTANT:
- Complete exactly ONE task per iteration
- Do not skip tasks — they must be done in order
- If a task fails verification, fix it before committing
- Keep $PROGRESS_FILE entries concise (2-4 lines per iteration)
- Do NOT mark the task as done in $TASKS_FILE — the review gate will do that"

  if ! run_claude "$MODEL_IMPLEMENT" "$prompt"; then
    log "IMPLEMENT failed after retries"
    return 1
  fi
  accum_cost "impl"

  printf "${C_GREEN}[$(timestamp)] IMPLEMENT: Done${C_RESET}\n"
  return 0
}

# =============================================================================
# Phase: REVIEW (each reviewer runs independently)
# =============================================================================

# Each reviewer outputs structured findings that get collected into review-deltas.md
# The implementer reads this file on re-implementation to apply fixes.
#
# Severity levels:
#   [CRITICAL] — blocks ship: crashes, data loss, security, broken core flow
#   [HIGH]     — must fix: wrong behavior, missing required functionality
#   [LOW]      — nice to fix: style, naming, minor improvements
#
# Only CRITICAL and HIGH trigger re-implementation.
# LOW findings are logged but don't block progress.

do_review_code() {
  printf "${C_YELLOW}[$(timestamp)] REVIEW [code]: Checking logic, bugs, style...${C_RESET}\n"
  save_state "review_code"

  local prompt="You are a CODE REVIEWER for a Vue 3 + TypeScript project.

TASK: Review the latest git commit for code quality issues.

STEPS:
1. Run: git diff HEAD~1 --name-only (to see which files changed)
2. Read CLAUDE.md for project coding rules
3. For each changed file, read the FULL file (not just the diff) to understand context
4. Check for issues listed below

WHAT TO CHECK:
- Logic errors: wrong conditions, off-by-one, unreachable code, infinite loops
- Type safety: missing type annotations, unsafe casts, any types
- Null safety: accessing properties without null checks on optional values
- Event handling: missing emit declarations, wrong emit payload types
- Reactivity bugs: destructuring props (loses reactivity), missing .value on refs in script
- Convention violations: missing defineOptions, hardcoded colors (should use tokens), <style> blocks (should use Tailwind)
- Import errors: wrong paths, missing imports, circular dependencies

WHAT TO IGNORE (do NOT report):
- Nitpicks about naming preferences
- Suggestions to add features not in the current task
- Comments about code that wasn't changed in this commit
- Suggestions to add error handling for impossible states

OUTPUT FORMAT — output ONLY lines matching this format, nothing else:
## code-review
- [CRITICAL] file:line — description. FIX: concrete instruction what to change
- [HIGH] file:line — description. FIX: concrete instruction what to change
- [LOW] file:line — description
- [OK] No issues found

RULES:
- Every CRITICAL and HIGH finding MUST include a FIX: instruction
- Be specific: 'file.vue:42' not just 'file.vue'
- If no issues found, output ONLY: ## code-review followed by - [OK] No issues found
- Do NOT output explanations, preamble, or summary — ONLY the formatted lines above"

  if ! run_claude "$MODEL_REVIEW" "$prompt"; then
    log "REVIEW [code] failed"
    return 1
  fi
  accum_cost "review"

  sanitize_review_output "code-review" "$CLAUDE_OUTPUT" >> "$REVIEW_DELTAS_FILE"
  return 0
}

do_review_design() {
  printf "${C_YELLOW}[$(timestamp)] REVIEW [design]: Running visual diff + structure + styles review...${C_RESET}\n"
  save_state "review_design"

  # ── Step 1: Run screenshot diff (standalone, no Claude needed) ──
  local screenshot_report=""
  local screenshot_summary=""
  if [ -f "screenshot-test.mjs" ]; then
    log "REVIEW [design]: Running screenshot comparison..."
    # Run screenshot test, capture output
    local screenshot_output
    screenshot_output=$(node screenshot-test.mjs 2>&1) || true

    if [ -f "screenshots/report.json" ]; then
      screenshot_report=$(cat screenshots/report.json)
      # Build human-readable summary from report
      if $HAS_JQ; then
        screenshot_summary=$(echo "$screenshot_report" | jq -r '
          .states[] |
          "  \(.id) \(.name): \(.matchPercent)% match (\(.status))"
        ' 2>/dev/null || echo "$screenshot_output")
      else
        screenshot_summary="$screenshot_output"
      fi
      log "REVIEW [design]: Screenshot results:"
      echo "$screenshot_summary"
    else
      log "REVIEW [design]: Screenshot test ran but no report generated"
      screenshot_summary="Screenshot test failed to generate report."
    fi
  else
    log "REVIEW [design]: No screenshot-test.mjs found, skipping visual diff"
    screenshot_summary="Visual diff skipped (screenshot-test.mjs not found)."
  fi

  # ── Step 2: Design review with Claude (code + screenshot context) ──
  local prompt="You are a DESIGN REVIEWER for a Vue 3 + Tailwind CSS v4 project.
Your goal is PIXEL PERFECT match with the design prototype.

TASK: Review the latest git commit for visual accuracy and design system compliance.

SCREENSHOT DIFF RESULTS:
$screenshot_summary

These results compare the running demo against the design prototype HTML.
Diff images are in screenshots/diff-*.png — states with FAIL or DRIFT need attention.

STEPS:
1. Run: git diff HEAD~1 --name-only (to see which files changed)
2. Read src/styles/tailwind.css to know the available @theme design tokens
3. Read CLAUDE.md — focus on 'Styling Rules' section
4. For each changed .vue file, read the FULL file to check template + classes
5. Read the prototype HTML at ../canonix-design/docs/handoff/tool-creation-wizard-v2/prototype.html — find the matching section for the component you're reviewing
6. Compare implementation classes/structure against prototype HTML

WHAT TO CHECK:
- PIXEL MATCH: compare your component's Tailwind classes against the prototype's inline styles and classes. Every padding, margin, color, font-size, font-weight, border-radius must match.
- Token compliance: hardcoded hex colors, pixel values, or raw Tailwind colors (e.g. 'bg-zinc-800') instead of design tokens ('bg-bg-surface')
- Reka UI: spec says to use a Reka primitive (Collapsible, RadioGroup, Dialog, Tabs, Progress, Splitter) but raw HTML is used instead
- Component structure: template nesting doesn't match prototype layout
- Spacing: compare gap/padding/margin values against prototype (px → Tailwind class mapping)
- Typography: font-size, font-weight, text-color must match prototype exactly
- Borders: border-width, border-color, border-radius must match
- Tailwind misuse: <style> or <style scoped> blocks exist (should be Tailwind-only)
- Accessibility: interactive elements missing aria-label

WHAT TO IGNORE:
- Animation timing tweaks
- Responsive breakpoints (desktop-only)

OUTPUT FORMAT — output ONLY lines matching this format, nothing else:
## design-review
- [CRITICAL] file — description. PROTO: what prototype has. DEMO: what demo has. FIX: exact Tailwind classes to change
- [HIGH] file — description. PROTO: X. DEMO: Y. FIX: instruction
- [LOW] file — description
- [OK] No issues found

SEVERITY:
- CRITICAL = layout broken, wrong component used, visible color mismatch, missing element
- HIGH = wrong spacing (>2px difference), wrong font-weight, wrong border-radius, missing token
- LOW = minor spacing (<2px), class ordering, aria-label missing
- Every CRITICAL and HIGH MUST include PROTO/DEMO/FIX fields
- If no issues, output ONLY: ## design-review followed by - [OK] No issues found
- Do NOT output explanations, preamble, or summary — ONLY the formatted lines above"

  if ! run_claude "$MODEL_REVIEW" "$prompt"; then
    log "REVIEW [design] failed"
    return 1
  fi
  accum_cost "review"

  sanitize_review_output "design-review" "$CLAUDE_OUTPUT" >> "$REVIEW_DELTAS_FILE"
  return 0
}

do_review_analyst() {
  printf "${C_YELLOW}[$(timestamp)] REVIEW [analyst]: Checking spec compliance...${C_RESET}\n"
  save_state "review_analyst"

  local prompt="You are a SYSTEM ANALYST reviewing implementation against specification.

TASK: Verify the latest git commit matches the task requirements and CLAUDE.md conventions.

STEPS:
1. Run: git diff HEAD~1 --name-only (to see which files changed)
2. Read CLAUDE.md — check that conventions are followed (defineOptions, import aliases, token usage, no hardcoded hex)
3. Read tasks.md — find the task that was just completed and verify all requirements were met
4. For each changed file, read the FULL file
5. If the task references HTML prototype line ranges, read those lines and compare styling classes

CHECKLIST FOR EACH COMPONENT:
- Props: every prop mentioned in the task exists with correct type and default value
- Emits: every emit mentioned in the task is declared with correct payload type
- Slots: every slot mentioned in the task exists with correct name and scope
- Styling: Tailwind classes match the source HTML prototype (mapped through design tokens)
- Data: mock data values match the HTML prototype exactly (names, counts, dates)
- Behavior: interactive elements work as described in the task

WHAT TO REPORT:
- SPEC-DRIFT: implementation differs from task requirements (wrong type, different behavior, renamed prop)
- MISSING: task requires something that is completely absent from implementation
- SCOPE-CREEP: implementation adds functionality not mentioned in the task (extra props, bonus features)
- STYLE-DRIFT: Tailwind classes don't match the HTML prototype source (wrong colors, spacing, layout)

WHAT TO IGNORE:
- Implementation details not specified in the task (internal variable names, helper functions)
- Performance optimizations that don't change behavior
- Comments and documentation

OUTPUT FORMAT — output ONLY lines matching this format, nothing else:
## analyst-review
- [CRITICAL] file — MISSING: description of what spec requires. FIX: what to add
- [CRITICAL] file — SPEC-DRIFT: what differs. SPEC says: X. Code does: Y. FIX: instruction
- [HIGH] file — MISSING/SPEC-DRIFT/SCOPE-CREEP: description. FIX: instruction
- [LOW] file — SCOPE-CREEP: description
- [OK] No issues found

RULES:
- CRITICAL = missing required prop/emit/slot, broken state transition, core behavior differs from spec
- HIGH = wrong default value, missing optional feature described in spec, minor scope creep
- LOW = extra convenience features that don't break anything
- Every CRITICAL and HIGH MUST include FIX: instruction
- If no issues, output ONLY: ## analyst-review followed by - [OK] No issues found
- Do NOT output explanations, preamble, or summary — ONLY the formatted lines above"

  if ! run_claude "$MODEL_REVIEW" "$prompt"; then
    log "REVIEW [analyst] failed"
    return 1
  fi
  accum_cost "review"

  sanitize_review_output "analyst-review" "$CLAUDE_OUTPUT" >> "$REVIEW_DELTAS_FILE"
  return 0
}

do_review_styles() {
  printf "${C_YELLOW}[$(timestamp)] REVIEW [styles]: Checking token usage, spacing, typography...${C_RESET}\n"
  save_state "review_styles"

  local prompt="You are a CSS/STYLES REVIEWER focused on pixel-perfect design token compliance.

TASK: Audit every Tailwind class in the latest commit against the design system tokens.

STEPS:
1. Run: git diff HEAD~1 --name-only (to see which .vue files changed)
2. Read src/styles/tailwind.css — extract ALL @theme tokens (colors, spacing, fonts)
3. Read the prototype HTML: ../canonix-design/docs/handoff/tool-creation-wizard-v2/prototype.html
4. For each changed .vue file, read the FULL template section
5. For every Tailwind class used, verify it maps to a design token

CHECKLIST — check EVERY instance:

COLORS:
- bg-zinc-*, text-zinc-*, border-zinc-* → MUST use token: bg-bg-surface, text-text-primary, border-border-default, etc.
- bg-violet-*, text-violet-* → MUST use token: bg-ai-muted, text-ai, border-ai-border
- bg-purple-*, text-purple-* → MUST use token: bg-accent-primary, text-accent-primary
- bg-green-*, text-green-* → MUST use token: text-success, bg-success-muted
- bg-red-*, text-red-* → MUST use token: text-error, bg-error-muted
- Any hex color (#xxx) → MUST be replaced with token
- Exception: bg-black/50 for backdrops is acceptable

SPACING (compare against prototype HTML):
- Read prototype element's padding/margin/gap classes
- Demo must use SAME values (p-3 vs p-4 matters)
- Report exact mismatch: 'PROTO: px-4 py-3, DEMO: px-3 py-2'

TYPOGRAPHY:
- Font sizes must match prototype: text-xs, text-sm, text-base
- Font weights must match: font-medium vs font-semibold
- Text colors must use tokens, not raw zinc/violet

BORDERS:
- border-radius: rounded-md vs rounded-lg matters
- border-width: border vs border-2
- border-color: must use token

OUTPUT FORMAT — output ONLY lines matching this format, nothing else:
## styles-review
- [CRITICAL] file:line — Raw color 'bg-zinc-900' used. TOKEN: bg-bg-surface. FIX: replace bg-zinc-900 with bg-bg-surface
- [HIGH] file:line — Spacing mismatch. PROTO: px-4 py-3. DEMO: px-3 py-2. FIX: change to px-4 py-3
- [HIGH] file:line — Font weight mismatch. PROTO: font-semibold. DEMO: font-medium. FIX: change to font-semibold
- [LOW] file:line — description
- [OK] No issues found

SEVERITY:
- CRITICAL = raw hex color, raw zinc/violet/purple color where token exists
- HIGH = wrong spacing (any difference), wrong font-weight, wrong border-radius
- LOW = class ordering, redundant classes
- If no issues, output ONLY: ## styles-review followed by - [OK] No issues found
- Do NOT output explanations — ONLY formatted lines"

  if ! run_claude "$MODEL_REVIEW" "$prompt"; then
    log "REVIEW [styles] failed"
    return 1
  fi
  accum_cost "review"

  sanitize_review_output "styles-review" "$CLAUDE_OUTPUT" >> "$REVIEW_DELTAS_FILE"
  return 0
}

# =============================================================================
# Review output processing
# =============================================================================

# Extract only structured review lines from claude output, discard preamble/postamble
# Usage: sanitize_review_output <section_name> <raw_output>
# Outputs: clean ## section header + bullet points only
sanitize_review_output() {
  local section="$1"
  local raw="$2"

  # Start with the section header
  echo "## $section"

  # Extract only lines that match our expected format: "- [TAG] ..."
  # This strips any preamble, explanation, or summary text
  local findings
  findings=$(echo "$raw" | grep -E '^\s*-\s*\[(CRITICAL|HIGH|LOW|OK)\]' || true)

  if [ -n "$findings" ]; then
    echo "$findings"
  else
    # If no structured lines found, the reviewer probably went off-format
    # Check if the raw output mentions any issues at all
    if echo "$raw" | grep -qi "no issues\|looks good\|all good\|no problems\|approved"; then
      echo "- [OK] No issues found"
    else
      # Has content but no structured format — wrap as a single HIGH finding
      echo "- [HIGH] (unstructured) Review output was not in expected format. Raw excerpt: $(echo "$raw" | head -c 300)"
    fi
  fi
  echo ""
}

# =============================================================================
# Phase: MERGE DELTAS
# =============================================================================

# Check if review deltas contain CRITICAL or HIGH findings that require re-implementation
# LOW findings are informational only — they don't trigger a re-implementation cycle
has_actionable_deltas() {
  if [ ! -f "$REVIEW_DELTAS_FILE" ]; then
    return 1
  fi

  if grep -q '\[CRITICAL\]\|\[HIGH\]' "$REVIEW_DELTAS_FILE"; then
    return 0
  fi

  return 1
}

# Print a summary of review findings to the terminal
print_review_summary() {
  if [ ! -f "$REVIEW_DELTAS_FILE" ]; then
    return
  fi

  local critical high low ok
  critical=$(grep '\[CRITICAL\]' "$REVIEW_DELTAS_FILE" 2>/dev/null | wc -l | tr -d ' ')
  high=$(grep '\[HIGH\]' "$REVIEW_DELTAS_FILE" 2>/dev/null | wc -l | tr -d ' ')
  low=$(grep '\[LOW\]' "$REVIEW_DELTAS_FILE" 2>/dev/null | wc -l | tr -d ' ')
  ok=$(grep '\[OK\]' "$REVIEW_DELTAS_FILE" 2>/dev/null | wc -l | tr -d ' ')

  local C_RED='\033[31m'
  if [ "$critical" -gt 0 ]; then
    printf "${C_RED}[$(timestamp)] REVIEW SUMMARY: ${critical} critical, ${high} high, ${low} low, ${ok} ok${C_RESET}\n"
  elif [ "$high" -gt 0 ]; then
    printf "${C_YELLOW}[$(timestamp)] REVIEW SUMMARY: ${critical} critical, ${high} high, ${low} low, ${ok} ok${C_RESET}\n"
  else
    printf "${C_GREEN}[$(timestamp)] REVIEW SUMMARY: ${critical} critical, ${high} high, ${low} low, ${ok} ok${C_RESET}\n"
  fi

  # Show critical and high findings inline for visibility
  if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
    printf "${C_DIM}  ┌── Actionable findings ──${C_RESET}\n"
    grep '\[CRITICAL\]\|\[HIGH\]' "$REVIEW_DELTAS_FILE" | while IFS= read -r line; do
      if echo "$line" | grep -q '\[CRITICAL\]'; then
        printf "${C_RED}  │ %s${C_RESET}\n" "$line"
      else
        printf "${C_YELLOW}  │ %s${C_RESET}\n" "$line"
      fi
    done
    printf "${C_DIM}  └──────────────────────────${C_RESET}\n"
  fi
}

# =============================================================================
# Phase: MARK DONE
# =============================================================================

do_mark_done() {
  printf "${C_CYAN}[$(timestamp)] MARK DONE: Marking task complete in $TASKS_FILE...${C_RESET}\n"
  save_state "mark_done"

  local prompt="Read $TASKS_FILE. Find the FIRST unchecked [ ] task.
Change [ ] to [x] for that task ONLY. Do not modify anything else.
Exit immediately."

  if ! run_claude "$MODEL_IMPLEMENT" "$prompt"; then
    log "MARK DONE failed"
    return 1
  fi

  return 0
}

# =============================================================================
# Main Loop
# =============================================================================

ITERATION=0
REVIEW_ROUND=0
CURRENT_TASK_ID=""
RESUMED_PHASE=""

# Try to resume from saved state
if load_state; then
  # Adjust iteration to continue from where we left off
  ITERATION=$((ITERATION - 1))  # will be incremented at top of loop
fi

echo ""
printf "${C_MAGENTA}[$(timestamp)] === Ralph Loop v2: Implement → Review → Iterate ===${C_RESET}\n"
echo ""

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
  ITERATION=$((ITERATION + 1))

  # Check remaining tasks
  REMAINING=$(grep -c '^\- \[ \]' "$TASKS_FILE" 2>/dev/null || true)

  if [ "$REMAINING" -eq 0 ]; then
    echo ""
    printf "${C_GREEN}[$(timestamp)] === All tasks complete! ($ITERATION iterations) ===${C_RESET}\n"
    clear_state
    exit 0
  fi

  # Extract current task ID and description
  CURRENT_TASK_ID=$(grep '^\- \[ \]' "$TASKS_FILE" | head -1 | grep -o '\*\*[0-9.]*\*\*' | tr -d '*' || true)
  CURRENT_TASK_DESC=$(grep '^\- \[ \]' "$TASKS_FILE" | head -1 | sed 's/.*\*\* //' | head -c 80 || true)

  printf "${C_CYAN}[$(timestamp)] --- Iteration $ITERATION | Task $CURRENT_TASK_ID | $REMAINING remaining ---${C_RESET}\n"
  [ -n "$CURRENT_TASK_DESC" ] && printf "${C_DIM}  %s${C_RESET}\n" "$CURRENT_TASK_DESC"

  # Reset review state and cost tracking for new task
  REVIEW_ROUND=0
  rm -f "$REVIEW_DELTAS_FILE"
  reset_task_cost

  # ── IMPLEMENT ──
  if ! do_implement; then
    log "Implementation failed, stopping."
    save_state "failed_implement"
    exit 1
  fi

  # ── REVIEW GATE ──
  while [ $REVIEW_ROUND -lt $MAX_REVIEW_ROUNDS ]; do
    REVIEW_ROUND=$((REVIEW_ROUND + 1))
    log "Review round $REVIEW_ROUND/$MAX_REVIEW_ROUNDS"

    # Clear previous deltas
    > "$REVIEW_DELTAS_FILE"
    rm -f /tmp/ralph-review-*.md

    # Screenshot diff runs first (blocking) — design reviewer needs the report
    if [ -f "screenshot-test.mjs" ]; then
      log "  Running screenshot diff..."
      node screenshot-test.mjs >/dev/null 2>&1 || true
    fi

    if $PARALLEL_REVIEWS; then
      # ── PARALLEL MODE ──
      # Each reviewer runs in a subshell with its own output file
      # Subshells isolate CLAUDE_OUTPUT and avoid file race conditions
      # Cost metrics are written to temp files and collected after wait
      log "Starting 4 reviewers in parallel..."
      rm -f /tmp/ralph-review-*.md /tmp/ralph-cost-*.txt

      (STREAM_OUTPUT=false REVIEW_DELTAS_FILE="/tmp/ralph-review-code.md" && do_review_code && echo "$LAST_CALL_COST $LAST_CALL_INPUT_TOKENS $LAST_CALL_OUTPUT_TOKENS" > /tmp/ralph-cost-code.txt) &
      pid_code=$!

      (STREAM_OUTPUT=false REVIEW_DELTAS_FILE="/tmp/ralph-review-design.md" && do_review_design && echo "$LAST_CALL_COST $LAST_CALL_INPUT_TOKENS $LAST_CALL_OUTPUT_TOKENS" > /tmp/ralph-cost-design.txt) &
      pid_design=$!

      (STREAM_OUTPUT=false REVIEW_DELTAS_FILE="/tmp/ralph-review-styles.md" && do_review_styles && echo "$LAST_CALL_COST $LAST_CALL_INPUT_TOKENS $LAST_CALL_OUTPUT_TOKENS" > /tmp/ralph-cost-styles.txt) &
      pid_styles=$!

      (STREAM_OUTPUT=false REVIEW_DELTAS_FILE="/tmp/ralph-review-analyst.md" && do_review_analyst && echo "$LAST_CALL_COST $LAST_CALL_INPUT_TOKENS $LAST_CALL_OUTPUT_TOKENS" > /tmp/ralph-cost-analyst.txt) &
      pid_analyst=$!

      # Wait for all reviewers to complete
      failed=0
      wait $pid_code    || failed=$((failed + 1))
      log "  [done] code reviewer"
      wait $pid_design  || failed=$((failed + 1))
      log "  [done] design reviewer"
      wait $pid_styles  || failed=$((failed + 1))
      log "  [done] styles reviewer"
      wait $pid_analyst || failed=$((failed + 1))
      log "  [done] analyst reviewer (${failed} failed)"

      # Collect cost metrics from subshells
      for f in /tmp/ralph-cost-*.txt; do
        if [ -f "$f" ]; then
          read -r cost_val input_val output_val < "$f" 2>/dev/null || true
          if [ -n "$cost_val" ]; then
            LAST_CALL_COST="$cost_val"
            LAST_CALL_INPUT_TOKENS="${input_val:-0}"
            LAST_CALL_OUTPUT_TOKENS="${output_val:-0}"
            accum_cost "review"
          fi
        fi
      done
      rm -f /tmp/ralph-cost-*.txt

      # Merge all results into single deltas file
      > "$REVIEW_DELTAS_FILE"
      for f in /tmp/ralph-review-code.md /tmp/ralph-review-design.md /tmp/ralph-review-styles.md /tmp/ralph-review-analyst.md; do
        if [ -f "$f" ] && [ -s "$f" ]; then
          cat "$f" >> "$REVIEW_DELTAS_FILE"
          echo "" >> "$REVIEW_DELTAS_FILE"
        fi
      done
      rm -f /tmp/ralph-review-*.md

    else
      # ── SEQUENTIAL MODE ──
      # Safer for low rate limits (1 API call at a time)
      log "Starting 4 reviewers sequentially..."
      do_review_code    || true
      do_review_design  || true
      do_review_styles  || true
      do_review_analyst || true
    fi

    # Show summary of all review findings
    print_review_summary

    # Check if any reviewer found CRITICAL or HIGH issues
    if has_actionable_deltas; then
      log "REVIEW: Actionable issues found. Re-implementing..."

      # Re-implement with review feedback
      if ! do_implement; then
        log "Re-implementation failed, stopping."
        save_state "failed_reimpl"
        exit 1
      fi
    else
      log "REVIEW: All reviewers approved. Moving on."
      break
    fi
  done

  if [ $REVIEW_ROUND -ge $MAX_REVIEW_ROUNDS ]; then
    log "WARNING: Max review rounds ($MAX_REVIEW_ROUNDS) reached. Force-accepting."
  fi

  # ── MARK DONE ──
  do_mark_done
  accum_cost "impl"  # mark_done uses MODEL_IMPLEMENT

  # ── LOG COSTS ──
  write_cost_log "$CURRENT_TASK_ID" "$CURRENT_TASK_DESC"

  # Cleanup
  rm -f "$REVIEW_DELTAS_FILE"
  clear_state

  printf "${C_CYAN}[$(timestamp)] --- Iteration $ITERATION complete ---${C_RESET}\n"
  sleep 2
done

echo ""
log "=== Max iterations ($MAX_ITERATIONS) reached ==="
exit 1
