#!/bin/bash
set -euo pipefail

# ============================================
# Ralph - Autonomous AI Coding Loop
# ============================================

# ============================================
# PROMPT TEMPLATE (edit this to tweak behavior)
# ============================================

PROMPT_TEMPLATE_JSON='Instructions:
1. Find the highest-priority incomplete task (done: false)
2. Implement it fully
3. Write tests and ensure they pass
4. Run linting and ensure it passes
5. Verify all acceptanceCriteria are met
6. Update the PRD file: set done: true for the completed task
7. Append any useful knowledge to progress.txt

ONLY WORK ON A SINGLE TASK.

If ALL TASKS have done: true, output <promise>COMPLETE</promise>.'

PROMPT_TEMPLATE_MD='Instructions:
1. Find the highest-priority incomplete task (marked - [ ])
2. Implement it fully
3. Write tests and ensure they pass
4. Run linting and ensure it passes
5. Verify all acceptanceCriteria are met
6. Update the PRD file: change - [ ] to - [x] for the completed task
7. Append any useful knowledge to progress.txt

ONLY WORK ON A SINGLE TASK.

If ALL TASKS are marked - [x], output <promise>COMPLETE</promise>.'

# ============================================
# Defaults
# ============================================

AGENT="claude"
SAFE_MODE=false
PRD_FILE="PRD.json"
PRD_FORMAT=""  # auto-detected: "json" or "markdown"
MAX_ITERATIONS=2
PROMPT_FILE=""
MODEL=""

# ============================================
# Colors & Terminal
# ============================================

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m'
  MAGENTA=$'\033[0;35m'
  CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
  # Agent brand colors
  CLAUDE_COLOR=$'\033[38;5;208m'  # Orange/tan (Anthropic)
  OPENCODE_COLOR=$'\033[1;37m'    # White
  # Cursor controls (use $'...' for actual escape chars)
  CLEAR_LINE=$'\033[2K'
  MOVE_UP=$'\033[1A'
  CR=$'\r'
else
  RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
  CLAUDE_COLOR='' OPENCODE_COLOR=''
  CLEAR_LINE='' MOVE_UP='' CR=''
fi

# Global state
AGENT_PID=""
MONITOR_PID=""
LOG_FILE=""
LOG_LINES=50

# ============================================
# Arg Parser
# ============================================

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--agent)
      AGENT="$2"
      shift 2
      ;;
    --safe)
      SAFE_MODE=true
      shift
      ;;
    --prd)
      PRD_FILE="$2"
      shift 2
      ;;
    -n|--max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --prompt)
      PROMPT_FILE="$2"
      shift 2
      ;;
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    --log-lines)
      LOG_LINES="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Ralph - Autonomous AI Coding Loop

Usage: ./ralph.sh [options]

Options:
  -a, --agent <name>    AI engine: claude, opencode (default: claude)
  -m, --model <name>    Model to use (e.g., sonnet, opus)
  --safe                Disable auto-permissions (prompts user)
  --prd <file>          PRD file (.json or .md) (default: PRD.json)
  -n, --max-iterations <n>  Max tasks to run, 0 = unlimited (default: 2)
  --log-lines <n>       Number of log lines to display (default: 20)
  --prompt <file>       Override prompt template with file contents
  -h, --help            Show this help
EOF
      exit 0
      ;;
    *)
      echo -e "${RED}[ERROR]${RESET} Unknown: $1" >&2
      exit 1
      ;;
  esac
done

# ============================================
# Validation
# ============================================

case "$AGENT" in
  claude|opencode) ;;
  *) echo -e "${RED}[ERROR]${RESET} Invalid agent: $AGENT (use: claude, opencode)" >&2; exit 1 ;;
esac

if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}[ERROR]${RESET} Invalid iterations: $MAX_ITERATIONS" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo -e "${RED}[ERROR]${RESET} jq required. Install: https://jqlang.github.io/jq/" >&2
  exit 1
fi

case "$AGENT" in
  claude)
    if ! command -v claude &>/dev/null; then
      echo -e "${RED}[ERROR]${RESET} claude CLI not found" >&2
      exit 1
    fi
    ;;
  opencode)
    if ! command -v opencode &>/dev/null; then
      echo -e "${RED}[ERROR]${RESET} opencode CLI not found" >&2
      exit 1
    fi
    ;;
esac

if [[ ! -f "$PRD_FILE" ]]; then
  echo -e "${RED}[ERROR]${RESET} PRD not found: $PRD_FILE" >&2
  exit 1
fi

# Detect format from extension
case "${PRD_FILE##*.}" in
  json) PRD_FORMAT="json" ;;
  md)   PRD_FORMAT="markdown" ;;
  *)
    echo -e "${RED}[ERROR]${RESET} Unknown PRD format: $PRD_FILE (expected .json or .md)" >&2
    exit 1
    ;;
esac

# Format-specific validation
if [[ "$PRD_FORMAT" == "json" ]]; then
  if ! jq empty "$PRD_FILE" 2>/dev/null; then
    echo -e "${RED}[ERROR]${RESET} Invalid JSON: $PRD_FILE" >&2
    exit 1
  fi

  # Validate all tasks have 'done' field
  missing_done=$(jq -r '[.[] | select(.done == null)] | if length > 0 then .[0].name // .[0].title // "index 0" else empty end' "$PRD_FILE" 2>/dev/null)
  if [[ -n "$missing_done" ]]; then
    echo -e "${RED}[ERROR]${RESET} Task '$missing_done' is missing the 'done' field" >&2
    echo "All tasks in $PRD_FILE must have a 'done': true|false field" >&2
    exit 1
  fi

elif [[ "$PRD_FORMAT" == "markdown" ]]; then
  if ! grep -q '^\- \[ \]' "$PRD_FILE"; then
    echo -e "${RED}[ERROR]${RESET} No tasks found in $PRD_FILE (expected '- [ ]' format)" >&2
    exit 1
  fi
fi

# Load prompt override if provided
PROMPT_TEMPLATE_OVERRIDE=""
if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo -e "${RED}[ERROR]${RESET} Prompt file not found: $PROMPT_FILE" >&2
    exit 1
  fi
  PROMPT_TEMPLATE_OVERRIDE=$(cat "$PROMPT_FILE")
fi

touch progress.txt

# ============================================
# PRD Functions
# ============================================

count_remaining() {
  case "$PRD_FORMAT" in
    json)
      jq '[.[] | select(.done == false)] | length' "$PRD_FILE"
      ;;
    markdown)
      grep -c '^\- \[ \]' "$PRD_FILE" 2>/dev/null || echo "0"
      ;;
  esac
}

count_completed() {
  case "$PRD_FORMAT" in
    json)
      jq '[.[] | select(.done == true)] | length' "$PRD_FILE"
      ;;
    markdown)
      grep -c '^\- \[x\]' "$PRD_FILE" 2>/dev/null || echo "0"
      ;;
  esac
}

get_next_task() {
  case "$PRD_FORMAT" in
    json)
      jq -r '[.[] | select(.done == false)][0] | .name // .title // "Task"' "$PRD_FILE" 2>/dev/null
      ;;
    markdown)
      grep -m1 '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' | head -c 60
      ;;
  esac
}

# ============================================
# Progress Monitor
# ============================================

monitor_progress() {
  local task="$1"
  local task_num="$2"
  local total_tasks="$3"
  local start_time=$SECONDS
  local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local spin_idx=0
  local last_line_count=0

  # Truncate task name for display
  task="${task:0:50}"

  while true; do
    local elapsed=$((SECONDS - start_time))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    local spin_char="${spinner:$spin_idx:1}"
    spin_idx=$(( (spin_idx + 1) % ${#spinner} ))

    # Clear previous output (move up and clear each line we printed before)
    for ((i = 0; i < last_line_count; i++)); do
      printf "${MOVE_UP}${CLEAR_LINE}"
    done

    # Print status line: ⠸ [2/4] Task name [00:02]
    printf "${CYAN}%s${RESET} ${DIM}[%d/%d]${RESET} ${BOLD}%s${RESET} ${DIM}[%02d:%02d]${RESET}\n" \
      "$spin_char" "$task_num" "$total_tasks" "$task" "$mins" "$secs"
    last_line_count=1

    # Print log lines if available (filter null bytes to avoid warnings)
    if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
      local log_output
      log_output=$(tail -n "$LOG_LINES" "$LOG_FILE" 2>/dev/null | tr -d '\0' | sed 's/^/  │ /')
      if [[ -n "$log_output" ]]; then
        printf "%s\n" "$log_output"
        local log_line_count
        log_line_count=$(printf "%s" "$log_output" | wc -l)
        last_line_count=$((last_line_count + log_line_count + 1))
      fi
    fi

    sleep 0.1
  done
}

# ============================================
# Agent Runner
# ============================================

run_agent() {
  local prompt="$1"
  local task="$2"
  local task_num="$3"
  local total_tasks="$4"
  local model_flag=""
  local start_time=$SECONDS

  if [[ -n "$MODEL" ]]; then
    model_flag="--model $MODEL"
  fi

  # Create temp file for logs
  LOG_FILE=$(mktemp)

  # Start progress monitor in background
  monitor_progress "$task" "$task_num" "$total_tasks" &
  MONITOR_PID=$!

  # Run agent in background, output to log file
  case "$AGENT" in
    claude)
      if [[ "$SAFE_MODE" == true ]]; then
        claude -p "$prompt" $model_flag > "$LOG_FILE" 2>&1 &
      else
        claude -p "$prompt" --dangerously-skip-permissions $model_flag > "$LOG_FILE" 2>&1 &
      fi
      ;;
    opencode)
      if [[ "$SAFE_MODE" == true ]]; then
        opencode run $model_flag "$prompt" > "$LOG_FILE" 2>&1 &
      else
        OPENCODE_PERMISSION='{"*":"allow"}' opencode run $model_flag "$prompt" > "$LOG_FILE" 2>&1 &
      fi
      ;;
  esac

  AGENT_PID=$!
  wait "$AGENT_PID" 2>/dev/null || true
  local exit_code=$?
  AGENT_PID=""

  # Stop monitor
  if [[ -n "$MONITOR_PID" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
  MONITOR_PID=""

  # Clear monitor output and show completion
  # Move up past the log lines and status (status line + up to LOG_LINES of logs)
  local actual_lines=0
  if [[ -f "$LOG_FILE" ]]; then
    actual_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    [[ $actual_lines -gt $LOG_LINES ]] && actual_lines=$LOG_LINES
  fi
  local lines_to_clear=$((actual_lines + 1))  # +1 for status line
  for ((i = 0; i < lines_to_clear; i++)); do
    printf "${MOVE_UP}${CLEAR_LINE}"
  done

  # Calculate elapsed time
  local elapsed=$((SECONDS - start_time))
  local mins=$((elapsed / 60))
  local secs=$((elapsed % 60))

  # Show final status with duration: ✓ [1/4] Task name completed [00:15]
  if [[ $exit_code -eq 0 ]]; then
    printf "${GREEN}✓${RESET} ${DIM}[%d/%d]${RESET} ${BOLD}%s${RESET} ${DIM}completed [%02d:%02d]${RESET}\n" \
      "$task_num" "$total_tasks" "${task:0:50}" "$mins" "$secs"
  else
    printf "${RED}✗${RESET} ${DIM}[%d/%d]${RESET} ${BOLD}%s${RESET} ${DIM}failed [%02d:%02d]${RESET}\n" \
      "$task_num" "$total_tasks" "${task:0:50}" "$mins" "$secs"
  fi

  # Cleanup log file
  rm -f "$LOG_FILE"
  LOG_FILE=""

  return $exit_code
}

# ============================================
# Prompt Builder
# ============================================

build_prompt() {
  local template
  if [[ -n "$PROMPT_TEMPLATE_OVERRIDE" ]]; then
    template="$PROMPT_TEMPLATE_OVERRIDE"
  else
    case "$PRD_FORMAT" in
      json)     template="$PROMPT_TEMPLATE_JSON" ;;
      markdown) template="$PROMPT_TEMPLATE_MD" ;;
    esac
  fi

  cat <<EOF
Read the PRD file $PRD_FILE and the progress.txt file.

$template
EOF
}

# ============================================
# Cleanup & Interrupt Handler
# ============================================

cleanup() {
  # Stop monitor first
  if [[ -n "$MONITOR_PID" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi

  # Stop agent
  if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
    kill "$AGENT_PID" 2>/dev/null || true
    wait "$AGENT_PID" 2>/dev/null || true
  fi

  # Cleanup log file
  [[ -n "$LOG_FILE" ]] && rm -f "$LOG_FILE"

  echo ""
  echo -e "${YELLOW}[WARN]${RESET} Interrupted! Cleaned up."
  exit 130
}

trap cleanup INT TERM

# ============================================
# Main Loop
# ============================================

echo -e "${BOLD}============================================${RESET}"
echo -e "${BOLD}Ralph${RESET} - Autonomous AI Coding Loop"
# Agent with brand color
case "$AGENT" in
  claude)   echo -e "  Agent:      ${CLAUDE_COLOR}claude${RESET}" ;;
  opencode) echo -e "  Agent:      ${OPENCODE_COLOR}opencode${RESET}" ;;
  *)        echo -e "  Agent:      ${BLUE}$AGENT${RESET}" ;;
esac
[[ -n "$MODEL" ]] && echo "  Model:      $MODEL"
echo "  PRD:        $PRD_FILE ($PRD_FORMAT)"
[[ -n "$PROMPT_FILE" ]] && echo "  Prompt:     $PROMPT_FILE"
if [[ "$MAX_ITERATIONS" -eq 0 ]]; then
  echo "  Max iter:   ∞"
else
  echo "  Max iter:   $MAX_ITERATIONS"
fi
[[ "$SAFE_MODE" == true ]] && echo -e "  Safe mode:  ${YELLOW}enabled${RESET}"
echo -e "${BOLD}============================================${RESET}"

iteration=0

# Calculate total tasks at start
completed_initial=$(count_completed)
remaining_initial=$(count_remaining)
total_tasks=$((completed_initial + remaining_initial))

while true; do
  ((++iteration))

  if [[ "$MAX_ITERATIONS" -gt 0 ]] && [[ "$iteration" -gt "$MAX_ITERATIONS" ]]; then
    echo -e "${YELLOW}[WARN]${RESET} Reached max iterations ($MAX_ITERATIONS)"
    break
  fi

  remaining=$(count_remaining)
  if [[ "$remaining" -eq 0 ]]; then
    echo -e "${GREEN}[OK]${RESET} All tasks complete!"
    break
  fi

  # Calculate current task number
  completed=$(count_completed)
  task_num=$((completed + 1))

  # Get current task name
  current_task=$(get_next_task)
  [[ -z "$current_task" ]] && current_task="Task $task_num"

  prompt=$(build_prompt)
  run_agent "$prompt" "$current_task" "$task_num" "$total_tasks"

  # Check if agent completed all tasks
  if [[ "$(count_remaining)" -eq 0 ]]; then
    echo -e "${GREEN}[OK]${RESET} All tasks complete!"
    break
  fi
done

echo -e "${BOLD}============================================${RESET}"
echo -e "${GREEN}Done.${RESET} Completed $((iteration - 1)) iteration(s)."
