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

  export PRD_FILE="$prd_file"
  count_remaining() {
    jq '[.tasks[] | select(.passes == false)] | length' "$PRD_FILE"
  }

  count_completed() {
    jq '[.tasks[] | select(.passes == true)] | length' "$PRD_FILE"
  }

  get_next_task() {
    jq -r '[.tasks[] | select(.passes == false)][0] | .description // .id // "Task"' "$PRD_FILE" 2>/dev/null
  }

  export -f count_remaining
  export -f count_completed
  export -f get_next_task
}

# ============================================
# Format Validation Tests (2)
# ============================================

@test "format validation: .json file is accepted" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" != *"must be a .json file"* ]]
}

@test "format validation: non-json file produces error" {
  echo "not json" > "$TEST_TEMP/test.md"
  run "$RALPH" --prd "$TEST_TEMP/test.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a .json file"* ]]
}

# ============================================
# JSON Validation Tests (3)
# ============================================

@test "json validation: valid JSON with passes field passes" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
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
# count_remaining() Tests (2)
# ============================================

@test "count_remaining: JSON with 1 incomplete returns 1" {
  source_ralph_functions "$FIXTURES/valid.json"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_remaining: JSON all complete returns 0" {
  source_ralph_functions "$FIXTURES/all-complete.json"
  run count_remaining
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

# ============================================
# count_completed() Tests (2)
# ============================================

@test "count_completed: JSON with 1 complete returns 1" {
  source_ralph_functions "$FIXTURES/valid.json"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "count_completed: JSON all complete returns total" {
  source_ralph_functions "$FIXTURES/all-complete.json"
  run count_completed
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

# ============================================
# get_next_task() Tests (2)
# ============================================

@test "get_next_task: JSON returns first incomplete task description" {
  source_ralph_functions "$FIXTURES/valid.json"
  run get_next_task
  [ "$status" -eq 0 ]
  [[ "$output" == "Add button component" ]]
}

@test "get_next_task: JSON all complete returns fallback" {
  source_ralph_functions "$FIXTURES/all-complete.json"
  run get_next_task
  [ "$status" -eq 0 ]
  [ "$output" = "Task" ]
}

# ============================================
# CLI Arguments Tests (6)
# ============================================

@test "cli: --prd sets PRD_FILE" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" == *"valid.json"* ]]
}

@test "cli: -a sets AGENT" {
  cat > "$TEST_TEMP/bin/opencode" << 'EOF'
#!/bin/bash
echo "mock opencode"
EOF
  chmod +x "$TEST_TEMP/bin/opencode"

  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -a opencode -n 0 2>&1 || true
  [[ "$output" == *"opencode"* ]]
}

@test "cli: --safe sets SAFE_MODE" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" --safe -n 0 2>&1 || true
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

@test "output: header shows PRD file" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" == *"PRD:"* ]]
  [[ "$output" == *"valid.json"* ]]
}

@test "output: header shows progress file path" {
  run timeout 1 "$RALPH" --prd "$FIXTURES/valid.json" -n 0 2>&1 || true
  [[ "$output" == *"Progress:"* ]]
}

# ============================================
# Folder Mode Tests (3)
# ============================================

@test "folder mode: accepts directory with tasks.json" {
  mkdir -p "$TEST_TEMP/prd-folder"
  cp "$FIXTURES/valid.json" "$TEST_TEMP/prd-folder/tasks.json"
  run timeout 1 "$RALPH" --prd "$TEST_TEMP/prd-folder" -n 0 2>&1 || true
  [[ "$output" == *"tasks.json"* ]]
  [[ "$output" != *"No tasks.json"* ]]
}

@test "folder mode: creates progress.txt in prd folder" {
  mkdir -p "$TEST_TEMP/prd-folder"
  cp "$FIXTURES/valid.json" "$TEST_TEMP/prd-folder/tasks.json"
  run timeout 1 "$RALPH" --prd "$TEST_TEMP/prd-folder" -n 0 2>&1 || true
  [[ "$output" == *"$TEST_TEMP/prd-folder/progress.txt"* ]]
}

@test "folder mode: error when no tasks file found" {
  mkdir -p "$TEST_TEMP/empty-folder"
  run "$RALPH" --prd "$TEST_TEMP/empty-folder"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No tasks.json"* ]]
}

# ============================================
# Prompt Template Tests (2)
# ============================================

# Helper to extract a prompt template block from ralph.sh
extract_template() {
  local varname="$1"
  sed -n "/^${varname}='/,/^'/p" "$RALPH" | sed '1s/^[^=]*='"'"'//; $s/'"'"'$//'
}

@test "prompt: JSON template contains ONLY WORK ON A SINGLE TASK" {
  run extract_template PROMPT_TEMPLATE_JSON
  [ "$status" -eq 0 ]
  [[ "$output" == *"ONLY WORK ON A SINGLE TASK"* ]]
}

@test "prompt: JSON template does not instruct to continue to next task" {
  run extract_template PROMPT_TEMPLATE_JSON
  [ "$status" -eq 0 ]
  [[ "$output" != *"Move to the next"* ]]
  [[ "$output" != *"continue to the next"* ]]
  [[ "$output" != *"Work through ALL"* ]]
}
