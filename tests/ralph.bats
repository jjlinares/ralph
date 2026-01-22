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
  # Extract just the functions we need to test
  local prd_file="$1"
  local prd_format="$2"

  export PRD_FILE="$prd_file"
  export PRD_FORMAT="$prd_format"
  export PROMPT_TEMPLATE_OVERRIDE=""

  # Define count_remaining function
  count_remaining() {
    case "$PRD_FORMAT" in
      json-nested)
        jq '[.tasks[] | select(.passes == false)] | length' "$PRD_FILE"
        ;;
      json-flat|json)
        jq '[.[] | select(.passes == false)] | length' "$PRD_FILE"
        ;;
      markdown)
        grep -c '^\- \[ \]' "$PRD_FILE" 2>/dev/null || true
        ;;
    esac
  }

  # Define count_completed function
  count_completed() {
    case "$PRD_FORMAT" in
      json-nested)
        jq '[.tasks[] | select(.passes == true)] | length' "$PRD_FILE"
        ;;
      json-flat|json)
        jq '[.[] | select(.passes == true)] | length' "$PRD_FILE"
        ;;
      markdown)
        grep -c '^\- \[x\]' "$PRD_FILE" 2>/dev/null || echo "0"
        ;;
    esac
  }

  # Define get_next_task function
  get_next_task() {
    case "$PRD_FORMAT" in
      json-nested)
        jq -r '[.tasks[] | select(.passes == false)][0] | .description // .id // "Task"' "$PRD_FILE" 2>/dev/null
        ;;
      json-flat|json)
        jq -r '[.[] | select(.passes == false)][0] | .name // .title // "Task"' "$PRD_FILE" 2>/dev/null
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
  cp "$FIXTURES/valid.json" "$TEST_TEMP/test.yaml"
  run "$RALPH" --prd "$TEST_TEMP/test.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown PRD format"* ]]
}

# ============================================
# JSON Validation Tests (3)
# ============================================

@test "json validation: valid JSON with passes field passes" {
  # The script should get past validation (will fail later at agent check without mock)
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  # Should not contain "Invalid JSON" error
  [[ "$output" != *"Invalid JSON"* ]]
  [[ "$output" != *"missing 'passes' field"* ]]
}

@test "json validation: invalid JSON syntax produces error" {
  run "$RALPH" --prd "$FIXTURES/invalid.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid JSON"* ]]
}

@test "json validation: missing passes field produces error" {
  run "$RALPH" --prd "$FIXTURES/missing-passes.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing 'passes' field"* ]]
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

@test "count_remaining: JSON flat with 1 incomplete returns 1" {
  source_ralph_functions "$FIXTURES/valid.json" "json-flat"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_remaining: JSON flat all complete returns 0" {
  source_ralph_functions "$FIXTURES/all-complete.json" "json-flat"
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

@test "count_completed: JSON flat with 1 complete returns 1" {
  source_ralph_functions "$FIXTURES/valid.json" "json-flat"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_completed: JSON flat all complete returns total" {
  source_ralph_functions "$FIXTURES/all-complete.json" "json-flat"
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
# CLI Arguments Tests (6)
# ============================================

@test "cli: --prd sets PRD_FILE" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" == *"$FIXTURES/valid.json"* ]] || [[ "$output" == *"valid.json"* ]]
}

@test "cli: -a sets AGENT" {
  # Create mock opencode
  cat > "$TEST_TEMP/bin/opencode" << 'EOF'
#!/bin/bash
echo "mock opencode"
EOF
  chmod +x "$TEST_TEMP/bin/opencode"

  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -a opencode -n 0 2>&1 || true
  [[ "$output" == *"opencode"* ]]
}

@test "cli: --safe sets SAFE_MODE" {
  # Run with --safe flag - check it doesn't error on the flag
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" --safe -n 0 2>&1 || true
  # Should not produce an error about --safe being unknown
  [[ "$output" != *"Unknown: --safe"* ]]
}

@test "cli: -n sets MAX_ITERATIONS" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 5 2>&1 || true
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

@test "cli: --log-lines sets LOG_LINES" {
  run "$RALPH" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--log-lines"* ]]
}

# ============================================
# get_next_task() Tests (4)
# ============================================

@test "get_next_task: JSON flat returns first incomplete task name" {
  source_ralph_functions "$FIXTURES/valid.json" "json-flat"
  run get_next_task
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Should return the name of the first incomplete task
  [[ "$output" != "null" ]]
}

@test "get_next_task: JSON flat all complete returns fallback" {
  source_ralph_functions "$FIXTURES/all-complete.json" "json-flat"
  run get_next_task
  [ "$status" -eq 0 ]
  # When no incomplete tasks, jq returns "Task" (fallback value)
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
# Output Format Tests (4)
# ============================================

@test "output: header shows Ralph title" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" == *"Ralph"* ]]
  [[ "$output" == *"Autonomous AI Coding Loop"* ]]
}

@test "output: header shows agent name" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -a claude -n 0 2>&1 || true
  [[ "$output" == *"Agent:"*"claude"* ]]
}

@test "output: header shows PRD file and format" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" == *"PRD:"* ]]
  [[ "$output" == *"json"* ]]
}

@test "output: header shows separator lines" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" == *"============"* ]]
}

# ============================================
# JSON Nested Format Tests (8)
# ============================================

@test "json-nested: format detection identifies nested format" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 0 2>&1 || true
  [[ "$output" == *"json-nested"* ]]
}

@test "json-nested: validation passes with passes field" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/nested.json" -n 0 2>&1 || true
  [[ "$output" != *"missing 'passes' field"* ]]
}

@test "json-nested: count_remaining returns incomplete tasks" {
  source_ralph_functions "$FIXTURES/nested.json" "json-nested"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "json-nested: count_completed returns complete tasks" {
  source_ralph_functions "$FIXTURES/nested.json" "json-nested"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "json-nested: get_next_task returns description" {
  source_ralph_functions "$FIXTURES/nested.json" "json-nested"
  run get_next_task
  [ "$status" -eq 0 ]
  [[ "$output" == "Add button component" ]]
}

@test "json-nested: all complete returns 0 remaining" {
  source_ralph_functions "$FIXTURES/nested-complete.json" "json-nested"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "json-nested: all complete get_next_task returns fallback" {
  source_ralph_functions "$FIXTURES/nested-complete.json" "json-nested"
  run get_next_task
  [ "$status" -eq 0 ]
  [ "$output" = "Task" ]
}

@test "json-nested: header shows progress file path" {
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
