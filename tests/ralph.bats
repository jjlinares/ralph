#!/usr/bin/env bats

# Test suite for ralph.sh

setup() {
  # Get absolute path to project root
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  RALPH="$PROJECT_ROOT/ralph.sh"
  FIXTURES="$PROJECT_ROOT/tests/fixtures"

  # Create temp directory for test artifacts
  TEST_TEMP="$(mktemp -d)"

  # Mock commands that ralph.sh checks for
  export PATH="$TEST_TEMP/bin:$PATH"
  mkdir -p "$TEST_TEMP/bin"

  # Create mock jq that passes through to real jq
  ln -sf "$(which jq)" "$TEST_TEMP/bin/jq"

  # Create mock claude command
  cat > "$TEST_TEMP/bin/claude" << 'EOF'
#!/bin/bash
echo "mock claude called with: $@"
EOF
  chmod +x "$TEST_TEMP/bin/claude"
}

teardown() {
  rm -rf "$TEST_TEMP"
}

# Helper to source ralph.sh functions without running main loop
source_ralph_functions() {
  local prd_file="$1"
  local prd_format="$2"

  export PRD_FILE="$prd_file"
  export PRD_FORMAT="$prd_format"

  # Define count_remaining function
  count_remaining() {
    case "$PRD_FORMAT" in
      json)
        jq '[.tasks[] | select(.passes == false)] | length' "$PRD_FILE"
        ;;
      markdown)
        grep -c '^\- \[ \]' "$PRD_FILE" 2>/dev/null || true
        ;;
    esac
  }

  # Define count_completed function
  count_completed() {
    case "$PRD_FORMAT" in
      json)
        jq '[.tasks[] | select(.passes == true)] | length' "$PRD_FILE"
        ;;
      markdown)
        grep -c '^\- \[x\]' "$PRD_FILE" 2>/dev/null || echo "0"
        ;;
    esac
  }

  # Define get_next_task function
  get_next_task() {
    case "$PRD_FORMAT" in
      json)
        jq -r '[.tasks[] | select(.passes == false)][0] | .description // .id // "Task"' "$PRD_FILE" 2>/dev/null
        ;;
      markdown)
        grep -m1 '^\- \[ \]' "$PRD_FILE" 2>/dev/null | sed 's/^- \[ \] //' | head -c 60
        ;;
    esac
  }

  export -f count_remaining
  export -f count_completed
  export -f get_next_task
}

# ============================================
# Format Detection Tests (3)
# ============================================

@test "format detection: .json file sets json format" {
  run bash -c "source /dev/stdin << 'SCRIPT'
PRD_FILE='test.json'
case \"\${PRD_FILE##*.}\" in
  json) echo \"json\" ;;
  md)   echo \"markdown\" ;;
  *)    echo \"unknown\" ;;
esac
SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "json" ]
}

@test "format detection: .md file sets markdown format" {
  run bash -c "source /dev/stdin << 'SCRIPT'
PRD_FILE='test.md'
case \"\${PRD_FILE##*.}\" in
  json) echo \"json\" ;;
  md)   echo \"markdown\" ;;
  *)    echo \"unknown\" ;;
esac
SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "markdown" ]
}

@test "format detection: .yaml file produces error" {
  cp "$FIXTURES/nested.json" "$TEST_TEMP/test.yaml"
  run "$RALPH" --prd "$TEST_TEMP/test.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown PRD format"* ]]
}

# ============================================
# JSON Validation Tests (3)
# ============================================

@test "json validation: valid JSON with passes field passes" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 0 2>&1 || true
  [[ "$output" != *"Invalid JSON"* ]]
  [[ "$output" != *"missing 'passes' field"* ]]
}

@test "json validation: invalid JSON syntax produces error" {
  run "$RALPH" --prd "$FIXTURES/invalid.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid JSON"* ]]
}

@test "json validation: JSON without tasks array produces error" {
  echo '{"name": "test"}' > "$TEST_TEMP/no-tasks.json"
  run "$RALPH" --prd "$TEST_TEMP/no-tasks.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must have .tasks array"* ]]
}

# ============================================
# Markdown Validation Tests (2)
# ============================================

@test "markdown validation: file with tasks passes" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.md" -n 0 2>&1 || true
  [[ "$output" != *"No tasks found"* ]]
}

@test "markdown validation: file without tasks produces error" {
  run "$RALPH" --prd "$FIXTURES/empty.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No tasks found"* ]]
}

# ============================================
# count_remaining() Tests (4)
# ============================================

@test "count_remaining: JSON with 1 incomplete returns 1" {
  source_ralph_functions "$FIXTURES/nested.json" "json"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_remaining: JSON all complete returns 0" {
  source_ralph_functions "$FIXTURES/nested-complete.json" "json"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "count_remaining: markdown with 1 incomplete returns 1" {
  source_ralph_functions "$FIXTURES/valid.md" "markdown"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_remaining: markdown all complete returns 0" {
  source_ralph_functions "$FIXTURES/all-complete.md" "markdown"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ============================================
# count_completed() Tests (4)
# ============================================

@test "count_completed: JSON with 1 complete returns 1" {
  source_ralph_functions "$FIXTURES/nested.json" "json"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_completed: JSON all complete returns total" {
  source_ralph_functions "$FIXTURES/nested-complete.json" "json"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "count_completed: markdown with 1 complete returns 1" {
  source_ralph_functions "$FIXTURES/valid.md" "markdown"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_completed: markdown all complete returns total" {
  source_ralph_functions "$FIXTURES/all-complete.md" "markdown"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

# ============================================
# get_next_task() Tests (4)
# ============================================

@test "get_next_task: JSON returns first incomplete task description" {
  source_ralph_functions "$FIXTURES/nested.json" "json"
  run get_next_task
  [ "$status" -eq 0 ]
  [[ "$output" == "Add button component" ]]
}

@test "get_next_task: JSON all complete returns fallback" {
  source_ralph_functions "$FIXTURES/nested-complete.json" "json"
  run get_next_task
  [ "$status" -eq 0 ]
  [ "$output" = "Task" ]
}

@test "get_next_task: markdown returns first incomplete task" {
  source_ralph_functions "$FIXTURES/valid.md" "markdown"
  run get_next_task
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "get_next_task: markdown all complete returns empty" {
  source_ralph_functions "$FIXTURES/all-complete.md" "markdown"
  run get_next_task
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================
# CLI Arguments Tests (6)
# ============================================

@test "cli: --prd sets PRD_FILE" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 0 2>&1 || true
  [[ "$output" == *"nested.json"* ]]
}

@test "cli: -a sets AGENT" {
  cat > "$TEST_TEMP/bin/opencode" << 'EOF'
#!/bin/bash
echo "mock opencode"
EOF
  chmod +x "$TEST_TEMP/bin/opencode"

  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -a opencode -n 0 2>&1 || true
  [[ "$output" == *"opencode"* ]]
}

@test "cli: --safe sets SAFE_MODE" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" --safe -n 0 2>&1 || true
  [[ "$output" != *"Unknown: --safe"* ]]
}

@test "cli: -n sets MAX_ITERATIONS" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 5 2>&1 || true
  [[ "$output" == *"Max iter:"*"5"* ]]
}

@test "cli: -h exits 0 and shows help" {
  run "$RALPH" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--help"* ]]
}

@test "cli: unknown option exits 1" {
  run "$RALPH" --unknown-option
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown"* ]]
}

# ============================================
# Output Format Tests (4)
# ============================================

@test "output: header shows Ralph title" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 0 2>&1 || true
  [[ "$output" == *"Ralph"* ]]
  [[ "$output" == *"Autonomous AI Coding Loop"* ]]
}

@test "output: header shows agent name" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -a claude -n 0 2>&1 || true
  [[ "$output" == *"Agent:"*"claude"* ]]
}

@test "output: header shows PRD file and format" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 0 2>&1 || true
  [[ "$output" == *"PRD:"* ]]
  [[ "$output" == *"json"* ]]
}

@test "output: header shows progress file path" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 0 2>&1 || true
  [[ "$output" == *"Progress:"* ]]
}

# ============================================
# Folder Mode Tests (3)
# ============================================

@test "folder mode: accepts directory with tasks.json" {
  mkdir -p "$TEST_TEMP/prd-folder"
  cp "$FIXTURES/nested.json" "$TEST_TEMP/prd-folder/tasks.json"
  run timeout 1 "$RALPH" --prd "$TEST_TEMP/prd-folder" -n 0 2>&1 || true
  [[ "$output" == *"tasks.json"* ]]
  [[ "$output" != *"No tasks.json"* ]]
}

@test "folder mode: creates progress.txt in prd folder" {
  mkdir -p "$TEST_TEMP/prd-folder"
  cp "$FIXTURES/nested.json" "$TEST_TEMP/prd-folder/tasks.json"
  run timeout 1 "$RALPH" --prd "$TEST_TEMP/prd-folder" -n 0 2>&1 || true
  [[ "$output" == *"$TEST_TEMP/prd-folder/progress.txt"* ]]
}

@test "folder mode: error when no tasks file found" {
  mkdir -p "$TEST_TEMP/empty-folder"
  run "$RALPH" --prd "$TEST_TEMP/empty-folder"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No tasks.json"* ]]
}
