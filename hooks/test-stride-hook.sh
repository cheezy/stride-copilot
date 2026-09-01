#!/usr/bin/env bash
# test-stride-hook.sh — Tests for stride-hook.sh pure bash replacements
#
# Tests all code paths without requiring awk, sed, or seq.
# Simulates jq-absent environments to exercise fallback paths.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stride-hook.sh"

# Colors (if terminal supports them)
RED=""
GREEN=""
RESET=""
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  RESET='\033[0m'
fi

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected: $(echo "$expected" | head -5)"
    echo "    actual:   $(echo "$actual" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $(echo "$haystack" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    echo -e "  ${GREEN}PASS${RESET}: $label (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected exit: $expected"
    echo "    actual exit:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ============================================================
# Setup: create temp directory with test fixtures
# ============================================================
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --- Test .stride.md files ---

cat > "$TMPDIR_TEST/basic.stride.md" << 'STRIDE'
## before_doing
```bash
echo "pulling latest"
echo "getting deps"
```

## after_doing
```bash
echo "running tests"
echo "running credo"
```

## before_review
```bash
echo "creating pr"
```

## after_review
```bash
echo "deploying"
```
STRIDE

cat > "$TMPDIR_TEST/with-comments.stride.md" << 'STRIDE'
## before_doing
```bash
# This is a comment
echo "step one"
   echo "indented step"
echo "step three"
# Another comment
```
STRIDE

cat > "$TMPDIR_TEST/no-hook.stride.md" << 'STRIDE'
## before_doing
```bash
echo "only before_doing here"
```
STRIDE

cat > "$TMPDIR_TEST/empty-block.stride.md" << 'STRIDE'
## after_doing
```bash
```
STRIDE

cat > "$TMPDIR_TEST/trailing-whitespace.stride.md" << 'STRIDE'
## before_doing
```bash
echo "found despite trailing whitespace"
```
STRIDE

cat > "$TMPDIR_TEST/multiple-code-blocks.stride.md" << 'STRIDE'
## before_doing

Some documentation text here.

```bash
echo "first command"
echo "second command"
```

More text and another block that should be ignored:

```bash
echo "should not appear"
```
STRIDE

cat > "$TMPDIR_TEST/no-bash-block.stride.md" << 'STRIDE'
## before_doing

Just some text, no code block.

## after_doing
```bash
echo "after_doing works"
```
STRIDE

cat > "$TMPDIR_TEST/adjacent-sections.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before"
```
## after_doing
```bash
echo "after"
```
STRIDE

# ============================================================
# Test Group 1: Pure bash JSON extraction (no-jq fallback)
# ============================================================
echo ""
echo "=== Test Group 1: JSON command extraction (no-jq fallback) ==="

# We test the extraction logic in isolation by inlining the same bash
# parameter expansion used in the script.

extract_command_bash() {
  local INPUT="$1"
  local _tmp COMMAND
  _tmp="${INPUT#*\"command\"}"
  if [ "$_tmp" = "$INPUT" ]; then
    COMMAND=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    COMMAND="${_tmp%%\"*}"
  fi
  echo "$COMMAND"
}

# 1a: Standard claim command
INPUT='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "standard claim URL" \
  "curl -X POST https://stridelikeaboss.com/api/tasks/claim" \
  "$RESULT"

# 1b: Complete command with task ID
INPUT='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "complete URL with ID" \
  "curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete" \
  "$RESULT"

# 1c: mark_reviewed command
INPUT='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/456/mark_reviewed"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "mark_reviewed URL" \
  "curl -X PATCH https://stridelikeaboss.com/api/tasks/456/mark_reviewed" \
  "$RESULT"

# 1d: No command key present
INPUT='{"tool_input":{"other_key":"some value"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "no command key returns empty" "" "$RESULT"

# 1e: Empty command value
INPUT='{"tool_input":{"command":""}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "empty command value" "" "$RESULT"

# 1f: Command with spaces in URL params
INPUT='{"tool_input":{"command":"curl -H Authorization: Bearer token123 https://example.com/api/tasks/claim"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "command with spaces" \
  "curl -H Authorization: Bearer token123 https://example.com/api/tasks/claim" \
  "$RESULT"

# 1g: JSON with whitespace around colon
INPUT='{"tool_input":{ "command" : "curl https://example.com/api/tasks/claim" }}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "whitespace around colon" \
  "curl https://example.com/api/tasks/claim" \
  "$RESULT"

# 1h: Completely unrelated JSON
INPUT='{"foo":"bar","baz":42}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "unrelated JSON returns empty" "" "$RESULT"

# ============================================================
# Test Group 2: .stride.md parser (pure bash while-read loop)
# ============================================================
echo ""
echo "=== Test Group 2: .stride.md section parser ==="

# Inline the parser logic as a function for isolated testing
parse_stride_md() {
  local STRIDE_MD="$1" HOOK_NAME="$2"
  local COMMANDS="" _found=0 _capture=0 _line _section

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _section="${_line#\#\# }"
        _section="${_section%"${_section##*[![:space:]]}"}"
        [ "$_section" = "$HOOK_NAME" ] && _found=1
        continue
        ;;
    esac
    if [ "$_found" -eq 1 ]; then
      case "$_line" in
        '```bash'*) _capture=1; continue ;;
        '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
      esac
      [ "$_capture" -eq 1 ] && COMMANDS="${COMMANDS}${_line}
"
    fi
  done < "$STRIDE_MD"

  printf '%s' "$COMMANDS"
}

# 2a: Parse before_doing from basic file
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_doing")
assert_contains "basic: before_doing line 1" 'echo "pulling latest"' "$RESULT"
assert_contains "basic: before_doing line 2" 'echo "getting deps"' "$RESULT"

# 2b: Parse after_doing from basic file
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "after_doing")
assert_contains "basic: after_doing line 1" 'echo "running tests"' "$RESULT"
assert_contains "basic: after_doing line 2" 'echo "running credo"' "$RESULT"

# 2c: Parse before_review
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_review")
assert_contains "basic: before_review" 'echo "creating pr"' "$RESULT"

# 2d: Parse after_review
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "after_review")
assert_contains "basic: after_review" 'echo "deploying"' "$RESULT"

# 2e: Doesn't bleed between sections
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_doing")
if echo "$RESULT" | grep -qF "running tests"; then
  echo -e "  ${RED}FAIL${RESET}: sections should not bleed into each other"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: sections do not bleed into each other"
  PASS=$((PASS + 1))
fi

# 2f: Hook not present in file
RESULT=$(parse_stride_md "$TMPDIR_TEST/no-hook.stride.md" "after_doing")
assert_eq "missing hook returns empty" "" "$RESULT"

# 2g: Empty code block
RESULT=$(parse_stride_md "$TMPDIR_TEST/empty-block.stride.md" "after_doing")
assert_eq "empty code block returns empty" "" "$RESULT"

# 2h: Comments and indentation are preserved (filtered later by CMD_LIST loop)
RESULT=$(parse_stride_md "$TMPDIR_TEST/with-comments.stride.md" "before_doing")
assert_contains "comments preserved in raw output" "# This is a comment" "$RESULT"
assert_contains "indented line preserved" 'echo "indented step"' "$RESULT"

# 2i: Trailing whitespace on section name
RESULT=$(parse_stride_md "$TMPDIR_TEST/trailing-whitespace.stride.md" "before_doing")
assert_contains "trailing whitespace trimmed from heading" 'echo "found despite trailing whitespace"' "$RESULT"

# 2j: Only first code block is captured
RESULT=$(parse_stride_md "$TMPDIR_TEST/multiple-code-blocks.stride.md" "before_doing")
assert_contains "first block captured" 'echo "first command"' "$RESULT"
if echo "$RESULT" | grep -qF "should not appear"; then
  echo -e "  ${RED}FAIL${RESET}: second code block should not be captured"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: second code block is ignored"
  PASS=$((PASS + 1))
fi

# 2k: Section with no bash block
RESULT=$(parse_stride_md "$TMPDIR_TEST/no-bash-block.stride.md" "before_doing")
assert_eq "no bash block returns empty" "" "$RESULT"

# 2l: Adjacent sections (no blank line between)
RESULT=$(parse_stride_md "$TMPDIR_TEST/adjacent-sections.stride.md" "before_doing")
assert_contains "adjacent: before_doing correct" 'echo "before"' "$RESULT"
if echo "$RESULT" | grep -qF 'echo "after"'; then
  echo -e "  ${RED}FAIL${RESET}: adjacent sections should not bleed"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: adjacent sections do not bleed"
  PASS=$((PASS + 1))
fi

RESULT=$(parse_stride_md "$TMPDIR_TEST/adjacent-sections.stride.md" "after_doing")
assert_contains "adjacent: after_doing correct" 'echo "after"' "$RESULT"

# ============================================================
# Test Group 3: Whitespace trimming (pure bash)
# ============================================================
echo ""
echo "=== Test Group 3: Whitespace trimming ==="

trim_leading() {
  local cmd="$1"
  local trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
  echo "$trimmed"
}

# 3a: Leading spaces
RESULT=$(trim_leading "   echo hello")
assert_eq "trim leading spaces" "echo hello" "$RESULT"

# 3b: Leading tabs
RESULT=$(trim_leading "		echo hello")
assert_eq "trim leading tabs" "echo hello" "$RESULT"

# 3c: Mixed spaces and tabs
RESULT=$(trim_leading "	  	echo hello")
assert_eq "trim mixed whitespace" "echo hello" "$RESULT"

# 3d: No leading whitespace
RESULT=$(trim_leading "echo hello")
assert_eq "no trim needed" "echo hello" "$RESULT"

# 3e: All whitespace
RESULT=$(trim_leading "   ")
assert_eq "all whitespace becomes empty" "" "$RESULT"

# 3f: Empty string
RESULT=$(trim_leading "")
assert_eq "empty string stays empty" "" "$RESULT"

# ============================================================
# Test Group 4: Command list building (comments/blanks filtered)
# ============================================================
echo ""
echo "=== Test Group 4: Command list building ==="

build_cmd_list() {
  local COMMANDS="$1"
  local CMD_LIST=()
  while IFS= read -r cmd; do
    local trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in \#*) continue ;; esac
    CMD_LIST+=("$trimmed")
  done <<< "$COMMANDS"
  [ ${#CMD_LIST[@]} -gt 0 ] && printf '%s\n' "${CMD_LIST[@]}" || true
}

# 4a: Filters comments and blank lines
COMMANDS='# comment
echo "step one"
   echo "indented step"

echo "step three"
# trailing comment'
RESULT=$(build_cmd_list "$COMMANDS")
LINES=$(echo "$RESULT" | wc -l | tr -d ' ')
assert_eq "filtered to 3 commands" "3" "$LINES"
assert_contains "keeps step one" 'echo "step one"' "$RESULT"
assert_contains "trims indented step" 'echo "indented step"' "$RESULT"
assert_contains "keeps step three" 'echo "step three"' "$RESULT"

# 4b: All comments/blanks
COMMANDS='# only comments

# more comments
'
RESULT=$(build_cmd_list "$COMMANDS")
# When all filtered, we get one empty line from printf of empty array
TRIMMED_RESULT="${RESULT#"${RESULT%%[![:space:]]*}"}"
assert_eq "all comments filtered to empty" "" "$TRIMMED_RESULT"

# ============================================================
# Test Group 5: Full integration (end-to-end via the script)
# ============================================================
echo ""
echo "=== Test Group 5: Full integration ==="

# Create a project directory with .stride.md
PROJ="$TMPDIR_TEST/project"
mkdir -p "$PROJ"
cat > "$PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing_executed"
```

## after_doing
```bash
echo "after_doing_executed"
```

## before_review
```bash
echo "before_review_executed"
```

## after_review
```bash
echo "after_review_executed"
```
STRIDE

# 5a: Claim triggers before_doing (post phase)
CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "claim exits 0" 0 "$EXIT_CODE"
assert_contains "claim runs before_doing" "before_doing_executed" "$OUTPUT"

# 5b: Pre-complete triggers after_doing (pre phase)
COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "pre-complete exits 0" 0 "$EXIT_CODE"
assert_contains "pre-complete runs after_doing" "after_doing_executed" "$OUTPUT"

# 5c: Post-complete triggers before_review (post phase)
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "post-complete exits 0" 0 "$EXIT_CODE"
assert_contains "post-complete runs before_review" "before_review_executed" "$OUTPUT"

# 5d: Mark-reviewed triggers after_review (post phase)
REVIEW_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}'
OUTPUT=$(echo "$REVIEW_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "mark-reviewed exits 0" 0 "$EXIT_CODE"
assert_contains "mark-reviewed runs after_review" "after_review_executed" "$OUTPUT"

# 5e: Non-stride command exits cleanly
OTHER_JSON='{"tool_input":{"command":"ls -la"}}'
OUTPUT=$(echo "$OTHER_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "non-stride exits 0" 0 "$EXIT_CODE"
assert_eq "non-stride produces no output" "" "$OUTPUT"

# 5f: No .stride.md exits cleanly
EMPTY_PROJ="$TMPDIR_TEST/empty-project"
mkdir -p "$EMPTY_PROJ"
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$EMPTY_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "no .stride.md exits 0" 0 "$EXIT_CODE"

# 5g: No phase argument exits cleanly
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" 2>&1)
EXIT_CODE=$?
assert_exit "no phase exits 0" 0 "$EXIT_CODE"

# 5h: Hook with failing command exits 2
FAIL_PROJ="$TMPDIR_TEST/fail-project"
mkdir -p "$FAIL_PROJ"
cat > "$FAIL_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "step one passes"
false
echo "step three should not run"
```
STRIDE
# Capture stderr (execution output) separately from stdout (JSON diagnostics)
FAIL_STDERR_FILE=$(mktemp)
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$FAIL_PROJ" bash "$HOOK_SCRIPT" post 2>"$FAIL_STDERR_FILE")
EXIT_CODE=$?
FAIL_STDERR=$(cat "$FAIL_STDERR_FILE")
rm -f "$FAIL_STDERR_FILE"
assert_exit "failing hook exits 2" 2 "$EXIT_CODE"
# The failure message stays on stderr — load-bearing for the PreToolUse
# blocking semantic (exit 2 + stderr message).
assert_contains "failing hook reports failure on stderr" "hook failed on command 2/3" "$FAIL_STDERR"
# D65: the earlier PASSING command's output must NOT leak to stderr. Before the
# fix, a successful command's stdout/stderr was catted to fd 2, which Claude
# Code rendered under a false "PreToolUse:Bash hook error" label.
if echo "$FAIL_STDERR" | grep -qF "step one passes"; then
  echo -e "  ${RED}FAIL${RESET}: passing command output must not appear on stderr"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: passing command output kept off stderr"
  PASS=$((PASS + 1))
fi
if echo "$FAIL_STDERR" | grep -qF "step three should not run"; then
  echo -e "  ${RED}FAIL${RESET}: should not run commands after failure"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: stops execution after failure"
  PASS=$((PASS + 1))
fi

# 5k: D65 — a fully PASSING gate writes nothing to stderr; per-command output
# is folded into the success JSON's commands_output on stdout instead. Capture
# stdout and stderr separately to assert the new contract.
OK_PROJ="$TMPDIR_TEST/ok-stderr-project"
mkdir -p "$OK_PROJ"
cat > "$OK_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "gate_line_one"
echo "gate_line_two"
```
STRIDE
OK_STDOUT_FILE=$(mktemp)
OK_STDERR_FILE=$(mktemp)
echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$OK_PROJ" bash "$HOOK_SCRIPT" pre >"$OK_STDOUT_FILE" 2>"$OK_STDERR_FILE"
EXIT_CODE=$?
OK_STDOUT=$(cat "$OK_STDOUT_FILE")
OK_STDERR=$(cat "$OK_STDERR_FILE")
rm -f "$OK_STDOUT_FILE" "$OK_STDERR_FILE"
assert_exit "passing gate exits 0" 0 "$EXIT_CODE"
assert_eq "passing gate writes nothing to stderr" "" "$OK_STDERR"
if command -v jq > /dev/null 2>&1; then
  assert_contains "passing gate emits commands_output" "commands_output" "$OK_STDOUT"
  assert_contains "passing gate output folded into JSON (1)" "gate_line_one" "$OK_STDOUT"
  assert_contains "passing gate output folded into JSON (2)" "gate_line_two" "$OK_STDOUT"
  # stdout must be a single parseable JSON object with status success
  if echo "$OK_STDOUT" | jq -e '.status == "success" and (.commands_output | type == "array")' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: success stdout is a single JSON object with commands_output array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: success stdout not a valid JSON object: $OK_STDOUT"
    FAIL=$((FAIL + 1))
  fi
else
  # No-jq degraded path: success emits no JSON at all and still writes nothing
  # to stderr.
  assert_eq "no-jq passing gate emits no stdout" "" "$OK_STDOUT"
fi

# 5l: D65 — a PASSING command that writes to STDERR (exit 0) is the exact
# production trigger ("All checks passed!" was a passing gate's output). Its
# stderr must NOT reach fd 2 (where Claude Code mislabels it); it must land in
# the success JSON's commands_output[].stderr instead.
STDERR_OK_PROJ="$TMPDIR_TEST/stderr-ok-project"
mkdir -p "$STDERR_OK_PROJ"
cat > "$STDERR_OK_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "compiling to stderr" >&2
```
STRIDE
SO_STDOUT_FILE=$(mktemp)
SO_STDERR_FILE=$(mktemp)
echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$STDERR_OK_PROJ" bash "$HOOK_SCRIPT" pre >"$SO_STDOUT_FILE" 2>"$SO_STDERR_FILE"
EXIT_CODE=$?
SO_STDOUT=$(cat "$SO_STDOUT_FILE")
SO_STDERR=$(cat "$SO_STDERR_FILE")
rm -f "$SO_STDOUT_FILE" "$SO_STDERR_FILE"
assert_exit "stderr-writing passing gate exits 0" 0 "$EXIT_CODE"
assert_eq "stderr-writing passing gate writes nothing to fd 2" "" "$SO_STDERR"
if command -v jq > /dev/null 2>&1; then
  if echo "$SO_STDOUT" | jq -e '.commands_output[0].stderr | contains("compiling to stderr")' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: passing command's stderr folded into commands_output[].stderr"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: passing command's stderr not in commands_output: $SO_STDOUT"
    FAIL=$((FAIL + 1))
  fi
fi

# 5i: Hook with multiple successful commands
MULTI_PROJ="$TMPDIR_TEST/multi-project"
mkdir -p "$MULTI_PROJ"
cat > "$MULTI_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "test_one"
echo "test_two"
echo "test_three"
```
STRIDE
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$MULTI_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "multi-command exits 0" 0 "$EXIT_CODE"
assert_contains "multi-command: step 1" "test_one" "$OUTPUT"
assert_contains "multi-command: step 2" "test_two" "$OUTPUT"
assert_contains "multi-command: step 3" "test_three" "$OUTPUT"

# 5j: Hook section not defined for this phase
PARTIAL_PROJ="$TMPDIR_TEST/partial-project"
mkdir -p "$PARTIAL_PROJ"
cat > "$PARTIAL_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "only before_doing"
```
STRIDE
OUTPUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PARTIAL_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "missing section exits 0" 0 "$EXIT_CODE"
assert_eq "missing section no output" "" "$OUTPUT"

# ============================================================
# Test Group 6: Edge cases
# ============================================================
echo ""
echo "=== Test Group 6: Edge cases ==="

# 6a: .stride.md with no trailing newline
NO_NEWLINE_PROJ="$TMPDIR_TEST/no-newline-project"
mkdir -p "$NO_NEWLINE_PROJ"
printf '## before_doing\n```bash\necho "no trailing newline"\n```' > "$NO_NEWLINE_PROJ/.stride.md"
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$NO_NEWLINE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "no trailing newline exits 0" 0 "$EXIT_CODE"
assert_contains "no trailing newline runs command" "no trailing newline" "$OUTPUT"

# 6b: Command with environment variable references
ENV_PROJ="$TMPDIR_TEST/env-project"
mkdir -p "$ENV_PROJ"
cat > "$ENV_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "home=$HOME"
```
STRIDE
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$ENV_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "env var expansion exits 0" 0 "$EXIT_CODE"
assert_contains "env var expanded" "home=$HOME" "$OUTPUT"

# 6c: .stride.md with CRLF line endings (Windows)
CRLF_PROJ="$TMPDIR_TEST/crlf-project"
mkdir -p "$CRLF_PROJ"
printf '## before_doing\r\n```bash\r\necho "crlf test"\r\n```\r\n' > "$CRLF_PROJ/.stride.md"
OUTPUT=$(echo "$CLAIM_JSON" | CLAUDE_PROJECT_DIR="$CRLF_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "CRLF line endings exits 0" 0 "$EXIT_CODE"
assert_contains "CRLF runs command" "crlf test" "$OUTPUT"

# 6d: JSON with tool_response (env caching path, requires jq)
if command -v jq > /dev/null 2>&1; then
  CACHE_PROJ="$TMPDIR_TEST/cache-project"
  mkdir -p "$CACHE_PROJ"
  cat > "$CACHE_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "id=$TASK_IDENTIFIER title=$TASK_TITLE"
```
STRIDE
  CLAIM_WITH_RESPONSE='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W99\",\"title\":\"Test Task\",\"status\":\"doing\",\"complexity\":\"small\",\"priority\":\"high\"}}"}'
  OUTPUT=$(echo "$CLAIM_WITH_RESPONSE" | CLAUDE_PROJECT_DIR="$CACHE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "env caching exits 0" 0 "$EXIT_CODE"
  assert_contains "env cache: identifier" "id=W99" "$OUTPUT"
  assert_contains "env cache: title" "title=Test Task" "$OUTPUT"
  # Clean up env cache
  rm -f "$CACHE_PROJ/.stride-env-cache"

  # 6e: host wraps API JSON inside tool_response.stdout (host Bash tool shape)
  CC_CLAIM='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":1526,\"identifier\":\"W217\",\"title\":\"Wrapped Task\",\"status\":\"in_progress\",\"complexity\":\"medium\",\"priority\":\"high\"}}","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}'
  OUTPUT=$(echo "$CC_CLAIM" | CLAUDE_PROJECT_DIR="$CACHE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "env caching (stdout wrapper) exits 0" 0 "$EXIT_CODE"
  assert_contains "env cache (wrapped): identifier" "id=W217" "$OUTPUT"
  assert_contains "env cache (wrapped): title" "title=Wrapped Task" "$OUTPUT"
  rm -f "$CACHE_PROJ/.stride-env-cache"
else
  echo "  SKIP: env caching tests (jq not available)"
fi

# ============================================================
# Test Group 7: Per-file diff capture (G148/W719 contract)
# ============================================================
echo ""
echo "=== Test Group 7: Per-file diff capture ==="

# Source the capture function from the hook script. The script's main flow
# only runs when stdin is provided and a hook name is matched, so sourcing it
# without those preconditions safely defines the function without executing
# anything.
if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: diff-capture tests (jq not available)"
elif ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: diff-capture tests (git not available)"
else
  # Mirror of the inline truncation logic for isolated unit testing.
  trunc_diff_inline() {
    local diff_text="$1"
    local max_lines="$2"
    local marker="$3"

    local line_count=0
    if [ -n "$diff_text" ]; then
      local _no_nl="${diff_text//$'\n'/}"
      line_count=$(( ${#diff_text} - ${#_no_nl} + 1 ))
    fi
    if [ "$line_count" -gt "$max_lines" ]; then
      local truncated
      truncated=$(printf '%s\n' "$diff_text" | head -n $((max_lines - 1)))
      printf '%s\n%s' "$truncated" "$marker"
    else
      printf '%s' "$diff_text"
    fi
  }

  # Mirror of the inline binary-detection logic for isolated unit testing.
  is_binary_in_numstat() {
    local numstat="$1" target="$2"
    local nl added rest deleted path
    while IFS= read -r nl; do
      added="${nl%%	*}"
      rest="${nl#*	}"
      deleted="${rest%%	*}"
      path="${rest#*	}"
      if [ "$added" = "-" ] && [ "$deleted" = "-" ] && [ "$path" = "$target" ]; then
        return 0
      fi
    done <<< "$numstat"
    return 1
  }

  # 7a: Truncation — diff at exactly 500 lines is not truncated
  EXACT_500=$(for i in $(seq 1 500); do echo "line $i"; done)
  RESULT=$(trunc_diff_inline "$EXACT_500" 500 "[diff truncated at 500 lines]")
  RESULT_LINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
  assert_eq "500-line diff: line count preserved" "500" "$RESULT_LINES"
  if echo "$RESULT" | grep -qF "[diff truncated at 500 lines]"; then
    echo -e "  ${RED}FAIL${RESET}: 500-line diff should not contain truncation marker"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 500-line diff is not truncated"
    PASS=$((PASS + 1))
  fi

  # 7b: Truncation — diff over 500 lines is truncated with the contract marker
  OVER_500=$(for i in $(seq 1 750); do echo "line $i"; done)
  RESULT=$(trunc_diff_inline "$OVER_500" 500 "[diff truncated at 500 lines]")
  RESULT_LINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
  assert_eq "750-line diff: truncated to 500 lines total" "500" "$RESULT_LINES"
  assert_contains "750-line diff: marker appended" \
    "[diff truncated at 500 lines]" \
    "$RESULT"
  # Last line should be the marker
  LAST_LINE=$(printf '%s\n' "$RESULT" | tail -n 1)
  assert_eq "750-line diff: marker is last line" \
    "[diff truncated at 500 lines]" \
    "$LAST_LINE"

  # 7c: Truncation — empty input stays empty
  RESULT=$(trunc_diff_inline "" 500 "[diff truncated at 500 lines]")
  assert_eq "empty diff stays empty" "" "$RESULT"

  # 7d: Binary detection — numstat with "- - <file>" returns true
  NUMSTAT='10	2	lib/foo.ex
-	-	assets/logo.png
3	0	test/foo_test.exs'
  if is_binary_in_numstat "$NUMSTAT" "assets/logo.png"; then
    echo -e "  ${GREEN}PASS${RESET}: binary file detected from numstat"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: binary file not detected"
    FAIL=$((FAIL + 1))
  fi

  # 7e: Binary detection — text file does not match
  if is_binary_in_numstat "$NUMSTAT" "lib/foo.ex"; then
    echo -e "  ${RED}FAIL${RESET}: text file misidentified as binary"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: text file correctly not flagged binary"
    PASS=$((PASS + 1))
  fi

  # 7f: Binary detection — file not in numstat
  if is_binary_in_numstat "$NUMSTAT" "nonexistent.txt"; then
    echo -e "  ${RED}FAIL${RESET}: missing file misidentified as binary"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: missing file correctly not flagged binary"
    PASS=$((PASS + 1))
  fi

  # 7g: Integration — capture_changed_files in a real temp git repo
  # Source the function from the hook script. Set arg empty to skip script main.
  CAPTURE_DIR=$(mktemp -d)
  (
    cd "$CAPTURE_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "original" > a.txt
    echo "original" > b.txt
    # Create a small binary file (PNG signature + nulls)
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x00\x00\x00\x00\x00' > logo.png
    git add . > /dev/null
    git commit -q -m "initial"

    # Capture the base
    BASE=$(git rev-parse HEAD)

    # Modify text + binary
    echo "modified" > a.txt
    printf '\x89PNG\r\n\x1a\n\xff\xff\xff\xff\xff\xff\xff\xff' > logo.png
    rm b.txt
    git add -A > /dev/null
    git commit -q -m "changes"

    # Source the capture function from the hook script.
    # The early-exit checks (no phase, no .stride.md) keep main from running.
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true

    capture_changed_files "$BASE"
  ) > "$CAPTURE_DIR/capture.json" 2> "$CAPTURE_DIR/capture.err"

  CAPTURE_OUTPUT=$(cat "$CAPTURE_DIR/capture.json")

  # Verify the output is a JSON array of length 3
  if echo "$CAPTURE_OUTPUT" | jq -e 'type == "array" and length == 3' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: integration: emits 3-entry JSON array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: integration: expected 3-entry array, got: $(echo "$CAPTURE_OUTPUT" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi

  # Text file should have a unified-patch diff
  TEXT_DIFF=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "a.txt") | .diff')
  # `grep -F` still treats a leading "--" as an option; pick a needle that
  # avoids that without weakening the assertion.
  assert_contains "integration: text file has unified-patch header" \
    "diff --git a/a.txt" \
    "$TEXT_DIFF"
  assert_contains "integration: text file has +/- lines" "+modified" "$TEXT_DIFF"

  # Binary file should have the exact placeholder
  BIN_DIFF=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "logo.png") | .diff')
  assert_eq "integration: binary file emits exact placeholder" \
    "[binary file — no diff captured]" \
    "$BIN_DIFF"

  # Deleted file (b.txt) still appears in the changed-files list
  DELETED_PRESENT=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "b.txt") | .path')
  assert_eq "integration: deleted file present in array" "b.txt" "$DELETED_PRESENT"

  rm -rf "$CAPTURE_DIR"

  # 7h: Fallback — non-repo directory returns empty array
  NONREPO_DIR=$(mktemp -d)
  (
    cd "$NONREPO_DIR" || exit 1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files ""
  ) > "$NONREPO_DIR/out.json" 2>/dev/null
  NONREPO_OUTPUT=$(cat "$NONREPO_DIR/out.json")
  if echo "$NONREPO_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: non-repo directory returns empty array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: non-repo expected [], got: $NONREPO_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NONREPO_DIR"

  # 7i: Fallback — empty base ref with a valid HEAD~1 still captures
  FALLBACK_DIR=$(mktemp -d)
  FALLBACK_OUT=$(mktemp)
  (
    cd "$FALLBACK_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "first" > c.txt
    git add c.txt > /dev/null
    git commit -q -m "first"
    echo "second" > c.txt
    git add c.txt > /dev/null
    git commit -q -m "second"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files ""
  ) > "$FALLBACK_OUT" 2>/dev/null
  FALLBACK_OUTPUT=$(cat "$FALLBACK_OUT")
  rm -f "$FALLBACK_OUT"
  if echo "$FALLBACK_OUTPUT" | jq -e 'type == "array" and length == 1 and .[0].path == "c.txt"' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: empty base falls back to HEAD~1 successfully"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: empty-base fallback expected single c.txt entry, got: $FALLBACK_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$FALLBACK_DIR"

  # 7j: End-to-end — after_doing hook writes .stride-changed-files.json
  E2E_DIR=$(mktemp -d)
  (
    cd "$E2E_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    # Gitignore the hook's runtime artifacts so they don't leak into the
    # snapshot via the Option D untracked-file capture.
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1 + gitignore"
    BASE=$(git rev-parse HEAD)
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v2"

    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran after_doing"
```
STRIDE

    # Pre-populate the env cache with the base ref the hook would have set
    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$E2E_DIR/.stride-changed-files.json" ]; then
    E2E_JSON=$(cat "$E2E_DIR/.stride-changed-files.json")
    if echo "$E2E_JSON" | jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: e2e: after_doing wrote correct .stride-changed-files.json"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: e2e: unexpected JSON contents: $E2E_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: e2e: .stride-changed-files.json was not written"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$E2E_DIR"

  # 7k: All-commented after_doing still triggers capture
  NOCMD_DIR=$(mktemp -d)
  (
    cd "$NOCMD_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > f.txt
    git add f.txt > /dev/null
    # Gitignore stride runtime artifacts (Option D would otherwise capture
    # the test-fixture .stride.md / .stride-env-cache as untracked files).
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
GITIGNORE
    git add .gitignore > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    echo "v2" > f.txt
    git add f.txt > /dev/null
    git commit -q -m "v2"

    cat > .stride.md << 'STRIDE'
## after_doing
```bash
# every command commented out
# echo "this never runs"
```
STRIDE

    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$NOCMD_DIR/.stride-changed-files.json" ]; then
    NOCMD_JSON=$(cat "$NOCMD_DIR/.stride-changed-files.json")
    if echo "$NOCMD_JSON" | jq -e 'type == "array" and length == 1 and .[0].path == "f.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: all-commented after_doing still triggers capture"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: all-commented after_doing: unexpected JSON: $NOCMD_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: all-commented after_doing did not write the JSON snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOCMD_DIR"

  # 7l: Legacy bypass — non-after_doing hooks must NOT touch the snapshot file
  # If a stale snapshot exists from a prior after_doing, before_review (or any
  # other phase) must leave it untouched. This preserves the backward-compat
  # guarantee: legacy code paths that don't run the capture continue to work.
  BYPASS_DIR=$(mktemp -d)
  (
    cd "$BYPASS_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > x.txt
    git add x.txt > /dev/null
    git commit -q -m "v1"

    cat > .stride.md << 'STRIDE'
## before_review
```bash
echo "ran before_review"
```
STRIDE

    # Pre-seed the snapshot file with a marker we can detect.
    echo '[{"path":"stale.txt","diff":"stale"}]' > .stride-changed-files.json

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    # `post` phase + complete URL → before_review (not after_doing)
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ -f "$BYPASS_DIR/.stride-changed-files.json" ]; then
    BYPASS_JSON=$(cat "$BYPASS_DIR/.stride-changed-files.json")
    if echo "$BYPASS_JSON" | jq -e '.[0].path == "stale.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: legacy bypass — before_review preserves snapshot file"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: legacy bypass — before_review overwrote the snapshot: $BYPASS_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: legacy bypass — before_review deleted the snapshot unexpectedly"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$BYPASS_DIR"

  # 7m: Empty changed-files list — base ref resolves but no files differ
  EMPTY_DIFF_DIR=$(mktemp -d)
  EMPTY_DIFF_OUT=$(mktemp)
  (
    cd "$EMPTY_DIFF_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > y.txt
    git add y.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Make a second commit with no real changes (use --allow-empty)
    git commit -q --allow-empty -m "empty"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$EMPTY_DIFF_OUT" 2>/dev/null
  EMPTY_DIFF_OUTPUT=$(cat "$EMPTY_DIFF_OUT")
  rm -f "$EMPTY_DIFF_OUT"
  if echo "$EMPTY_DIFF_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: empty changed-files list returns []"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: empty changed-files expected [], got: $EMPTY_DIFF_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$EMPTY_DIFF_DIR"

  # 7n: File with embedded null bytes — git --numstat reports as binary, so the
  # placeholder must be emitted (no patch attempt)
  NULL_DIR=$(mktemp -d)
  (
    cd "$NULL_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'plain text\n' > nullfile.dat
    git add nullfile.dat > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Replace contents with bytes that include nulls
    printf 'text\x00with\x00nulls\n' > nullfile.dat
    git add nullfile.dat > /dev/null
    git commit -q -m "v2"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$NULL_DIR/out.json" 2>/dev/null
  NULL_OUTPUT=$(cat "$NULL_DIR/out.json")
  NULL_DIFF=$(echo "$NULL_OUTPUT" | jq -r '.[0].diff // ""')
  assert_eq "null-byte file emits binary placeholder" \
    "[binary file — no diff captured]" \
    "$NULL_DIFF"
  rm -rf "$NULL_DIR"

  # ---------------------------------------------------------------------------
  # Test Group 7 (Option D semantic) — cases 7o-7s
  # The snapshot must reflect the agent's working state at completion time:
  # modified-uncommitted tracked files, staged-uncommitted changes, untracked
  # new files (synthesized new-file patches), untracked binaries (placeholder),
  # and dedupe when a path is both committed-since-base AND further modified
  # in the working tree.
  # ---------------------------------------------------------------------------

  # 7o: Modified-uncommitted tracked file appears in the snapshot
  UNCOMMITTED_DIR=$(mktemp -d)
  (
    cd "$UNCOMMITTED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Modify the tracked file WITHOUT committing or staging
    echo "v2-uncommitted" > tracked.txt

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNCOMMITTED_DIR/out.json" 2>/dev/null
  UNCOMMITTED_OUTPUT=$(cat "$UNCOMMITTED_DIR/out.json")
  UNCOMMITTED_DIFF=$(echo "$UNCOMMITTED_OUTPUT" | jq -r '.[] | select(.path == "tracked.txt") | .diff')
  if [ -n "$UNCOMMITTED_DIFF" ]; then
    assert_contains "Option D: modified-uncommitted tracked file has unified-patch header" \
      "diff --git a/tracked.txt" \
      "$UNCOMMITTED_DIFF"
    assert_contains "Option D: modified-uncommitted tracked file diff body present" \
      "+v2-uncommitted" \
      "$UNCOMMITTED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: modified-uncommitted tracked file missing from snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UNCOMMITTED_DIR"

  # 7p: Staged-uncommitted change appears in the snapshot
  STAGED_DIR=$(mktemp -d)
  (
    cd "$STAGED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > staged.txt
    git add staged.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Modify and stage WITHOUT committing
    echo "v2-staged" > staged.txt
    git add staged.txt > /dev/null

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$STAGED_DIR/out.json" 2>/dev/null
  STAGED_OUTPUT=$(cat "$STAGED_DIR/out.json")
  STAGED_DIFF=$(echo "$STAGED_OUTPUT" | jq -r '.[] | select(.path == "staged.txt") | .diff')
  if [ -n "$STAGED_DIFF" ]; then
    assert_contains "Option D: staged-uncommitted file has unified-patch header" \
      "diff --git a/staged.txt" \
      "$STAGED_DIFF"
    assert_contains "Option D: staged-uncommitted file diff body present" \
      "+v2-staged" \
      "$STAGED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: staged-uncommitted file missing from snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$STAGED_DIR"

  # 7q: Untracked new file appears as synthesized new-file patch
  UNTRACKED_DIR=$(mktemp -d)
  (
    cd "$UNTRACKED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > existing.txt
    git add existing.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Create a NEW untracked file
    cat > new_file.txt << 'NEW'
line one
line two
line three
NEW

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNTRACKED_DIR/out.json" 2>/dev/null
  UNTRACKED_OUTPUT=$(cat "$UNTRACKED_DIR/out.json")
  UNTRACKED_DIFF=$(echo "$UNTRACKED_OUTPUT" | jq -r '.[] | select(.path == "new_file.txt") | .diff')
  if [ -n "$UNTRACKED_DIFF" ]; then
    # Synthesized new-file patch should have the +++ b/<path> header and at
    # least one `+<content>` body line.
    assert_contains "Option D: untracked new file has +++ b/<path> header" \
      "+++ b/new_file.txt" \
      "$UNTRACKED_DIFF"
    assert_contains "Option D: untracked new file has +<content> body lines" \
      "+line one" \
      "$UNTRACKED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: untracked new file missing from snapshot (output: $UNTRACKED_OUTPUT)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UNTRACKED_DIR"

  # 7r: Untracked binary uses the binary placeholder
  UNTRACKED_BIN_DIR=$(mktemp -d)
  (
    cd "$UNTRACKED_BIN_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > a.txt
    git add a.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Create an untracked file with NUL bytes (binary)
    printf 'binary\x00data\x00here\n' > new.bin

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNTRACKED_BIN_DIR/out.json" 2>/dev/null
  UNTRACKED_BIN_OUTPUT=$(cat "$UNTRACKED_BIN_DIR/out.json")
  UNTRACKED_BIN_DIFF=$(echo "$UNTRACKED_BIN_OUTPUT" | jq -r '.[] | select(.path == "new.bin") | .diff')
  assert_eq "Option D: untracked binary file emits exact binary placeholder" \
    "[binary file — no diff captured]" \
    "$UNTRACKED_BIN_DIFF"
  rm -rf "$UNTRACKED_BIN_DIR"

  # 7s: Dedupe — committed-and-further-modified path appears exactly once
  DEDUPE_DIR=$(mktemp -d)
  (
    cd "$DEDUPE_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > dual.txt
    git add dual.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Commit a change…
    echo "v2-committed" > dual.txt
    git add dual.txt > /dev/null
    git commit -q -m "v2"

    # …then modify the same path further WITHOUT committing
    echo "v3-uncommitted-on-top" > dual.txt

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$DEDUPE_DIR/out.json" 2>/dev/null
  DEDUPE_OUTPUT=$(cat "$DEDUPE_DIR/out.json")
  DEDUPE_COUNT=$(echo "$DEDUPE_OUTPUT" | jq -r '[.[] | select(.path == "dual.txt")] | length')
  assert_eq "Option D: dedupe — committed + further-modified path appears exactly once" \
    "1" \
    "$DEDUPE_COUNT"
  # And the diff should reflect the FINAL working-tree state (not the
  # intermediate committed value).
  DEDUPE_DIFF=$(echo "$DEDUPE_OUTPUT" | jq -r '.[] | select(.path == "dual.txt") | .diff')
  assert_contains "Option D: dedupe — diff reflects final working-tree content" \
    "+v3-uncommitted-on-top" \
    "$DEDUPE_DIFF"
  rm -rf "$DEDUPE_DIR"

  # 7t (D67): the hook's OWN root artifacts (.stride-diff-upload-state and
  # .stride-changed-files.json) are excluded from the snapshot when untracked,
  # while a legitimate changed file is still captured. Output is captured via
  # command substitution (not a redirect into the repo dir) so the output file
  # itself never appears as an untracked entry in the snapshot.
  EXCL_DIR=$(mktemp -d)
  EXCL_OUTPUT=$(
    cd "$EXCL_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > real.txt
    git add real.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    echo "changed" > real.txt
    # The hook's own untracked bookkeeping artifacts at the repo root.
    printf 'task_id=42\nhttp_code=200\n' > .stride-diff-upload-state
    printf '[]\n' > .stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  EXCL_STATE=$(echo "$EXCL_OUTPUT" | jq -r '[.[] | select(.path == ".stride-diff-upload-state")] | length')
  assert_eq "D67: untracked upload-state file excluded from snapshot" "0" "$EXCL_STATE"
  EXCL_SNAP=$(echo "$EXCL_OUTPUT" | jq -r '[.[] | select(.path == ".stride-changed-files.json")] | length')
  assert_eq "D67: snapshot file itself excluded from snapshot" "0" "$EXCL_SNAP"
  EXCL_REAL=$(echo "$EXCL_OUTPUT" | jq -r '.[] | select(.path == "real.txt") | .path')
  assert_eq "D67: legitimate changed file still captured" "real.txt" "$EXCL_REAL"
  rm -rf "$EXCL_DIR"

  # 7u (D67): a COMMITTED upload-state file that differs from base is still
  # excluded — this is the after_doing auto-commit case that polluted W1098.
  EXCL2_DIR=$(mktemp -d)
  EXCL2_OUTPUT=$(
    cd "$EXCL2_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'task_id=1\nhttp_code=200\n' > .stride-diff-upload-state
    echo "v1" > real.txt
    git add -A > /dev/null
    git commit -q -m "v1 (state file committed)"
    BASE=$(git rev-parse HEAD)
    # Auto-commit case: both the state file and a real file change, then commit.
    printf 'task_id=2\nhttp_code=200\n' > .stride-diff-upload-state
    echo "v2" > real.txt
    git add -A > /dev/null
    git commit -q -m "v2"
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  EXCL2_STATE=$(echo "$EXCL2_OUTPUT" | jq -r '[.[] | select(.path == ".stride-diff-upload-state")] | length')
  assert_eq "D67: committed+modified upload-state file excluded" "0" "$EXCL2_STATE"
  EXCL2_REAL=$(echo "$EXCL2_OUTPUT" | jq -r '.[] | select(.path == "real.txt") | .path')
  assert_eq "D67: real file still captured alongside excluded state file" "real.txt" "$EXCL2_REAL"
  rm -rf "$EXCL2_DIR"

  # 7v (D67): the exclusion is anchored to the repo ROOT — same-named files in a
  # subdirectory belong to the user's project and must still be captured.
  EXCL3_DIR=$(mktemp -d)
  EXCL3_OUTPUT=$(
    cd "$EXCL3_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > root.txt
    git add root.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    mkdir -p sub
    printf 'user data\n' > sub/.stride-diff-upload-state
    printf 'user snapshot\n' > sub/.stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  EXCL3_SUB1=$(echo "$EXCL3_OUTPUT" | jq -r '.[] | select(.path == "sub/.stride-diff-upload-state") | .path')
  assert_eq "D67: same-named file in a subdirectory is still captured (state)" \
    "sub/.stride-diff-upload-state" "$EXCL3_SUB1"
  EXCL3_SUB2=$(echo "$EXCL3_OUTPUT" | jq -r '.[] | select(.path == "sub/.stride-changed-files.json") | .path')
  assert_eq "D67: same-named file in a subdirectory is still captured (snapshot)" \
    "sub/.stride-changed-files.json" "$EXCL3_SUB2"
  rm -rf "$EXCL3_DIR"

  # 7w (D67): when the hook artifacts are the ONLY changed paths, the snapshot
  # is still a valid empty JSON array.
  EXCL4_DIR=$(mktemp -d)
  EXCL4_OUTPUT=$(
    cd "$EXCL4_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > real.txt
    git add real.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # real.txt is unchanged; only the hook's own untracked artifacts appear.
    printf 'task_id=9\nhttp_code=200\n' > .stride-diff-upload-state
    printf '[]\n' > .stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) 2>/dev/null
  if echo "$EXCL4_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: D67: artifacts-only working tree yields a valid empty array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: D67: expected empty array, got: $EXCL4_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$EXCL4_DIR"
fi

# ============================================================
# Test Group 8: after_goal end-to-end routing (W790)
# ============================================================
# Covers the four required after_goal scenarios end-to-end (full script
# subprocess), exercising the W788 routing changes in stride-hook.sh.
# Fixtures use generic synthetic URLs and task IDs per the W790 pitfall.
echo ""
echo "=== Test Group 8: after_goal end-to-end routing (W790) ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 8 requires jq for response parsing"
else
  AG_E2E_PROJ="$TMPDIR_TEST/after-goal-e2e"
  mkdir -p "$AG_E2E_PROJ"
  cat > "$AG_E2E_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "after_goal_ran for $GOAL_IDENTIFIER"
```
STRIDE

  ag_e2e_input() {
    local primary_command="$1"
    local hooks_json="$2"
    local inner_json
    inner_json=$(jq -nc --argjson hooks "$hooks_json" '{data: {id: 99}, hooks: $hooks}')
    jq -nc \
      --arg cmd "$primary_command" \
      --arg inner "$inner_json" \
      '{tool_input: {command: $cmd}, tool_response: {stdout: $inner}}'
  }

  # 8a: after_goal entry in response + ## after_goal section present.
  AG_E2E_INPUT_PRESENT=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '[{"name":"after_doing"},{"name":"before_review"},{"name":"after_review"},{"name":"after_goal"}]')
  AG_E2E_OUT_PRESENT=$(echo "$AG_E2E_INPUT_PRESENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_PRESENT=$?
  assert_exit "8a: end-to-end after_goal present exits 0" 0 "$AG_E2E_RC_PRESENT"
  assert_contains "8a: primary before_review ran" "before_review_ran" "$AG_E2E_OUT_PRESENT"
  assert_contains "8a: after_goal section ran" "after_goal_ran" "$AG_E2E_OUT_PRESENT"
  assert_contains "8a: structured success JSON for after_goal on stdout" \
    '"hook": "after_goal"' "$AG_E2E_OUT_PRESENT"

  # 8b: after_goal entry in response + ## after_goal section ABSENT (back-compat).
  AG_E2E_PROJ_MISSING="$TMPDIR_TEST/after-goal-e2e-missing"
  mkdir -p "$AG_E2E_PROJ_MISSING"
  cat > "$AG_E2E_PROJ_MISSING/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```
STRIDE
  AG_E2E_OUT_MISSING=$(echo "$AG_E2E_INPUT_PRESENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ_MISSING" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_MISSING=$?
  assert_exit "8b: end-to-end after_goal-missing-section exits 0 (back-compat)" 0 \
    "$AG_E2E_RC_MISSING"
  assert_contains "8b: primary before_review still ran" "before_review_ran" "$AG_E2E_OUT_MISSING"
  if echo "$AG_E2E_OUT_MISSING" | grep -qF '"hook": "after_goal"'; then
    echo -e "  ${RED}FAIL${RESET}: 8b: missing ## after_goal should emit no after_goal JSON"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 8b: missing ## after_goal emits no after_goal JSON"
    PASS=$((PASS + 1))
  fi

  # 8c: after_goal NOT in response -> behavior unchanged.
  AG_E2E_INPUT_ABSENT=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '[{"name":"after_doing"},{"name":"before_review"},{"name":"after_review"}]')
  AG_E2E_OUT_ABSENT=$(echo "$AG_E2E_INPUT_ABSENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_ABSENT=$?
  assert_exit "8c: end-to-end after_goal-absent exits 0" 0 "$AG_E2E_RC_ABSENT"
  assert_contains "8c: primary before_review ran" "before_review_ran" "$AG_E2E_OUT_ABSENT"
  if echo "$AG_E2E_OUT_ABSENT" | grep -qF "after_goal_ran"; then
    echo -e "  ${RED}FAIL${RESET}: 8c: after_goal absent should NOT execute the section"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 8c: after_goal absent does not execute the section"
    PASS=$((PASS + 1))
  fi

  # 8d: after_goal section command exits non-zero -> structured failure JSON
  # on stdout; script exit code stays 0 (primary curl already succeeded).
  AG_E2E_PROJ_FAIL="$TMPDIR_TEST/after-goal-e2e-fail"
  mkdir -p "$AG_E2E_PROJ_FAIL"
  cat > "$AG_E2E_PROJ_FAIL/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
bash -c 'exit 11'
```
STRIDE
  AG_E2E_OUT_FAIL=$(echo "$AG_E2E_INPUT_PRESENT" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ_FAIL" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_FAIL=$?
  assert_exit "8d: end-to-end after_goal-failure does not propagate as script exit" 0 \
    "$AG_E2E_RC_FAIL"
  assert_contains "8d: structured failed JSON references after_goal on stdout" \
    '"hook": "after_goal"' "$AG_E2E_OUT_FAIL"
  assert_contains "8d: structured failed JSON has status:failed" \
    '"status": "failed"' "$AG_E2E_OUT_FAIL"
  assert_contains "8d: structured failed JSON carries non-zero exit_code" \
    '"exit_code": 11' "$AG_E2E_OUT_FAIL"

  # 8e: mark_reviewed URL also routes after_goal.
  AG_E2E_INPUT_MR=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed" \
    '[{"name":"after_review"},{"name":"after_goal"}]')
  AG_E2E_OUT_MR=$(echo "$AG_E2E_INPUT_MR" | CLAUDE_PROJECT_DIR="$AG_E2E_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_E2E_RC_MR=$?
  assert_exit "8e: end-to-end after_goal on mark_reviewed exits 0" 0 "$AG_E2E_RC_MR"
  assert_contains "8e: mark_reviewed runs after_review" "after_review_ran" "$AG_E2E_OUT_MR"
  assert_contains "8e: mark_reviewed runs after_goal" "after_goal_ran" "$AG_E2E_OUT_MR"

  # --- W1512: after_goal hook.env forwarding ---
  # Helper: build a tool_input + tool_response payload whose after_goal hook
  # entry carries a server-supplied `env` object. Mirrors ag_e2e_input but
  # attaches env to the after_goal entry so we can assert the bridge exports it.
  ag_e2e_input_env() {
    local primary_command="$1"
    local env_json="$2"
    local inner_json
    inner_json=$(jq -nc --argjson env "$env_json" \
      '{data: {id: 99}, hooks: [{name: "after_review"}, {name: "after_goal", env: $env}]}')
    jq -nc \
      --arg cmd "$primary_command" \
      --arg inner "$inner_json" \
      '{tool_input: {command: $cmd}, tool_response: {stdout: $inner}}'
  }

  # Fixture whose after_goal section echoes every forwarded variable so the
  # assertions can confirm each reached the section process environment.
  AG_ENV_PROJ="$TMPDIR_TEST/after-goal-env"
  mkdir -p "$AG_ENV_PROJ"
  cat > "$AG_ENV_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal_id=$GOAL_ID id=$GOAL_IDENTIFIER title=$GOAL_TITLE desc=$GOAL_DESCRIPTION board=$BOARD_ID col=$COLUMN_ID agent=$AGENT_NAME"
```
STRIDE

  # 8f: a stubbed hook.env with GOAL_*/BOARD_*/COLUMN_*/AGENT_NAME reaches the
  # after_goal section environment, copied VERBATIM (spaces preserved).
  AG_ENV_INPUT=$(ag_e2e_input_env \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '{"GOAL_ID":"4687","GOAL_IDENTIFIER":"G4687","GOAL_TITLE":"Ship the bridge","GOAL_DESCRIPTION":"Wire GOAL_* through","BOARD_ID":"55","COLUMN_ID":"128","AGENT_NAME":"Claude Opus 4.8"}')
  AG_ENV_OUT=$(echo "$AG_ENV_INPUT" | CLAUDE_PROJECT_DIR="$AG_ENV_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_ENV_RC=$?
  assert_exit "8f: after_goal env-export exits 0" 0 "$AG_ENV_RC"
  assert_contains "8f: GOAL_ID exported verbatim" "goal_id=4687" "$AG_ENV_OUT"
  assert_contains "8f: GOAL_IDENTIFIER exported verbatim" "id=G4687" "$AG_ENV_OUT"
  assert_contains "8f: GOAL_TITLE with spaces exported verbatim" "title=Ship the bridge" "$AG_ENV_OUT"
  assert_contains "8f: GOAL_DESCRIPTION exported verbatim" "desc=Wire GOAL_* through" "$AG_ENV_OUT"
  assert_contains "8f: BOARD_ID exported verbatim" "board=55" "$AG_ENV_OUT"
  assert_contains "8f: COLUMN_ID exported verbatim" "col=128" "$AG_ENV_OUT"
  assert_contains "8f: AGENT_NAME with spaces exported verbatim" "agent=Claude Opus 4.8" "$AG_ENV_OUT"

  # 8g: an after_goal entry with NO env object is a clean no-op — the section
  # still runs (exit 0) with the GOAL_* vars empty, never an error. Uses a FRESH
  # project dir so the (W1612) env-cache GOAL_* persisted by 8f above does not
  # leak in via the env-cache load — 8g must observe a genuinely empty GOAL_*.
  AG_NOENV_PROJ="$TMPDIR_TEST/after-goal-noenv"
  mkdir -p "$AG_NOENV_PROJ"
  cp "$AG_ENV_PROJ/.stride.md" "$AG_NOENV_PROJ/.stride.md"
  AG_NOENV_INPUT=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '[{"name":"after_review"},{"name":"after_goal"}]')
  AG_NOENV_OUT=$(echo "$AG_NOENV_INPUT" | CLAUDE_PROJECT_DIR="$AG_NOENV_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  AG_NOENV_RC=$?
  assert_exit "8g: after_goal missing env is a clean no-op (exit 0)" 0 "$AG_NOENV_RC"
  assert_contains "8g: section still runs with empty GOAL_* vars" \
    "goal_id= id= title=" "$AG_NOENV_OUT"

  # ----------------------------------------------------------
  # D118 (W1624): canonical response-file fast path
  # ----------------------------------------------------------
  # The harness truncates large /complete tool_response.stdout mid-JSON, so
  # response_has_after_goal / export_after_goal_env must prefer a canonical
  # response file ($PROJECT_DIR/.stride/.last-api-response.json) when present
  # and fall back to tool_response.stdout otherwise. These source the hook to
  # exercise the functions in isolation, overriding $RESPONSE_FILE (the script
  # computes it from $PROJECT_DIR at source time; overriding it post-source is
  # the function-level seam).
  RF_DIR="$TMPDIR_TEST/d118-respfile"
  RF_FILE="$RF_DIR/.stride/.last-api-response.json"
  mkdir -p "$RF_DIR/.stride"

  # Full, valid API response carrying an after_goal entry with an env object
  # (what a non-truncated response file holds).
  RF_FULL='{"data":{"id":99},"hooks":[{"name":"after_review"},{"name":"after_goal","env":{"GOAL_ID":"4687","GOAL_IDENTIFIER":"G4687"}}]}'
  # A tool_response.stdout truncated mid-JSON by the harness — invalid JSON.
  RF_TRUNC_STDOUT='{"data":{},"hooks":[{"name":"after_go'
  RF_INPUT_TRUNC=$(jq -nc --arg s "$RF_TRUNC_STDOUT" \
    '{tool_input:{command:"curl"},tool_response:{stdout:$s}}')
  # Small, valid CC-wrapped inputs carrying after_goal for the back-compat path.
  RF_INPUT_VALID=$(ag_e2e_input \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '[{"name":"after_review"},{"name":"after_goal"}]')
  RF_INPUT_VALID_ENV=$(ag_e2e_input_env \
    "curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete" \
    '{"GOAL_ID":"555","GOAL_IDENTIFIER":"G555"}')

  # 8h (D118, regression): truncated tool_response.stdout + present response
  # file with after_goal → response_has_after_goal succeeds via the file.
  printf '%s' "$RF_FULL" > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_TRUNC"
  )
  assert_exit "8h: after_goal detected from response file despite truncated stdout" 0 "$?"

  # 8i (D118): no response file + truncated stdout → detection fails (documents
  # the bug and fallback; D119's fresh call is the reliability guarantee).
  rm -f "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_TRUNC"
  )
  RF_RC_NOFILE=$?
  if [ "$RF_RC_NOFILE" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${RESET}: 8i: no response file + truncated stdout returns non-zero (fallback)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8i: expected non-zero with no file and truncated stdout"
    FAIL=$((FAIL + 1))
  fi

  # 8j (D118, back-compat): no response file + valid stdout with after_goal →
  # detection still succeeds from tool_response.stdout.
  rm -f "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_VALID"
  )
  assert_exit "8j: after_goal still detected from stdout when no response file (back-compat)" 0 "$?"

  # 8k (D118, edge): empty response file → ignored, falls through to stdout.
  : > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_VALID"
  )
  assert_exit "8k: empty response file falls through to stdout parse" 0 "$?"

  # 8l (D118, edge): response file present but not valid JSON → ignored, falls
  # through to stdout (a truncated/garbage file must not shadow the fallback).
  printf '%s' "$RF_TRUNC_STDOUT" > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_VALID"
  )
  assert_exit "8l: invalid-JSON response file falls through to stdout parse" 0 "$?"

  # 8m (D118, pitfall): HAS_JQ=false degrades cleanly even with a present file.
  printf '%s' "$RF_FULL" > "$RF_FILE"
  (
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=false
    RESPONSE_FILE="$RF_FILE"
    response_has_after_goal "$RF_INPUT_TRUNC"
  )
  RF_RC_NOJQ=$?
  if [ "$RF_RC_NOJQ" -ne 0 ]; then
    echo -e "  ${GREEN}PASS${RESET}: 8m: HAS_JQ=false returns non-zero even with present response file"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 8m: expected non-zero with HAS_JQ=false"
    FAIL=$((FAIL + 1))
  fi

  # 8n (D119): export_after_goal_env exports GOAL_* from an ALREADY-RESOLVED
  # payload (its signature takes a resolved payload after the D119 refactor — the
  # caller resolves via extract_response_payload; the file-first behavior now
  # lives in the resolver, covered end-to-end by 8q).
  RF_GOAL_FROM_PAYLOAD=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    export_after_goal_env "$RF_FULL"
    echo "${GOAL_ID:-}"
  )
  assert_eq "8n: export_after_goal_env exports GOAL_ID from a resolved payload" "4687" "$RF_GOAL_FROM_PAYLOAD"

  # 8o (D119): an after_goal entry without an env object is a clean no-op — the
  # GOAL_* vars stay empty, never an error.
  RF_NOENV_PAYLOAD='{"hooks":[{"name":"after_review"},{"name":"after_goal"}]}'
  RF_NOENV_GOAL=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    export_after_goal_env "$RF_NOENV_PAYLOAD"
    echo "GID=[${GOAL_ID:-}]"
  )
  assert_eq "8o: export_after_goal_env is a clean no-op for an after_goal entry without env" "GID=[]" "$RF_NOENV_GOAL"

  # ----------------------------------------------------------
  # W1609: shared resolver + capture (fast-path additions)
  # ----------------------------------------------------------
  # 8p (W1609): the shared resolver extract_response_payload recovers the W1086
  # persisted-output file when stdout carries only a "Full output saved to:
  # <path>" notice and no canonical file is present.
  rm -f "$RF_FILE"
  RF_PERSIST_DIR=$(mktemp -d)
  RF_PERSIST_FILE="$RF_PERSIST_DIR/persisted.json"
  printf '{"data":{"id":88},"hooks":[{"name":"after_goal"}]}' > "$RF_PERSIST_FILE"
  RF_NOTICE_INPUT=$(jq -nc --arg s "Full output saved to: $RF_PERSIST_FILE" \
    '{tool_input:{command:"curl"},tool_response:{stdout:$s}}')
  RF_PAYLOAD_PERSIST=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    HAS_JQ=true
    RESPONSE_FILE="$RF_FILE"
    extract_response_payload "$RF_NOTICE_INPUT"
  )
  assert_contains "8p: resolver recovers the W1086 persisted-output file via notice" '"after_goal"' "$RF_PAYLOAD_PERSIST"
  rm -rf "$RF_PERSIST_DIR"

  # 8q (W1609): a /complete whose tool_response.stdout is truncated mid-JSON but
  # which has a present canonical response file carrying the after_goal entry
  # still routes into ## after_goal AND exports the server-supplied GOAL_* env
  # from the file — end-to-end proof that after_goal detection and
  # export_after_goal_env both read file-first under a truncated stdout.
  AG_FILE_PROJ="$TMPDIR_TEST/w1609-file-e2e"
  mkdir -p "$AG_FILE_PROJ/.stride"
  cat > "$AG_FILE_PROJ/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```

## after_goal
```bash
echo "gident=[$GOAL_IDENTIFIER]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"parent_id":55},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"7","GOAL_IDENTIFIER":"G7","GOAL_TITLE":"Goal Seven"}}]}' \
    > "$AG_FILE_PROJ/.stride/.last-api-response.json"
  # Deliberately truncated stdout (invalid JSON) — the file must be the source.
  AG_FILE_INPUT=$(jq -nc --arg s '{"data":{"id":99,"parent' \
    '{tool_input:{command:"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"},tool_response:{stdout:$s}}')
  AG_FILE_OUT=$(echo "$AG_FILE_INPUT" | CLAUDE_PROJECT_DIR="$AG_FILE_PROJ" \
    bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "8q: truncated /complete stdout still runs after_goal via the canonical file" \
    "gident=[G7]" "$AG_FILE_OUT"

  rm -f "$RF_FILE"
fi

# ============================================================
# Test Group 9: PUT snapshot upload (W838 — G162 port)
# ============================================================
# finalize_after_doing PUTs the snapshot to {URL}/api/tasks/{TASK_ID}/changed_files
# after writing it to disk. URL+token are extracted from the intercepted
# agent completion request ($COMMAND). Failures must be silent.
echo ""
echo "=== Test Group 9: PUT snapshot upload (W838) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 9 requires both"
else
  # Helper to build the curl stub. Writes args + stdin into $1 and exits $2.
  make_curl_stub() {
    local stub_dir="$1" fixture="$2" exit_code="${3:-0}" http_code="${4:-}"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/curl" << CURLSTUB
#!/usr/bin/env bash
{
  printf 'ARGS:'
  for a in "\$@"; do printf ' %s' "\$a"; done
  printf '\n'
} >> "$fixture"
# Record body for assertions. Two forms are recognized:
#   1. --data-binary @<file>   (legacy bare-array shape)
#   2. -d <inline-body>        (current wrapped-object shape)
prev=""
for a in "\$@"; do
  case "\$prev" in
    -d|--data|--data-raw)
      printf 'BODY:\n%s\n' "\$a" >> "$fixture"
      ;;
  esac
  case "\$a" in
    @*)
      printf 'BODY:\n' >> "$fixture"
      cat "\${a#@}" >> "$fixture" 2>/dev/null || true
      printf '\n' >> "$fixture"
      ;;
  esac
  prev="\$a"
done
# Emit an HTTP code on stdout so the hook's curl -w '%{http_code}' capture has
# a value to fold into .stride-diff-upload-state (W1094). Empty by default for
# back-compat with tests that don't assert on the recorded code.
printf '%s' '$http_code'
exit $exit_code
CURLSTUB
    chmod +x "$stub_dir/curl"
  }

  # Extract the BODY section emitted by make_curl_stub from a fixture file.
  # (W1093) after_doing now PUTs twice — an early pre-commands capture plus the
  # post-commands refresh — so the fixture can hold two ARGS/BODY records.
  # Capture stops at the next ARGS line and the LAST body wins: the refresh is
  # the authoritative final upload that must match the on-disk snapshot.
  extract_body() {
    awk '/^BODY:$/{flag=1; body=""; next} /^ARGS:/{flag=0} flag && /^$/{flag=0} flag{body = body $0 ORS} END{printf "%s", body}' "$1"
  }

  # Shared fixture: a git repo with one tracked change since BASE.
  setup_put_repo() {
    local dir="$1"
    cd "$dir" || return 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    # curl-call.txt is the stub recorder; it must be gitignored or the (W1093)
    # post-commands refresh capture would pick it up as an untracked file and
    # skew the snapshot the round-trip assertions compare against. The W1094
    # upload-state file needs the same treatment.
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
    PUT_BASE=$(git rev-parse HEAD)
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v2"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran after_doing"
```
STRIDE
    printf "TASK_ID='42'\nTASK_BASE_REF='%s'\n" "$PUT_BASE" > .stride-env-cache
  }

  # 9a: PUT-success — token+URL in $COMMAND triggers a PUT with the snapshot body
  PUT_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  PUT_FIXTURE="$PUT_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$PUT_FIXTURE" 0
  (
    setup_put_repo "$PUT_DIR" || exit 1
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer test_token_abc123\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$PUT_FIXTURE" ]; then
    PUT_CONTENTS=$(cat "$PUT_FIXTURE")
    assert_contains "9a: PUT call targets /api/tasks/42/changed_files" \
      "https://stride.example.com/api/tasks/42/changed_files" "$PUT_CONTENTS"
    assert_contains "9a: PUT call sends Bearer token from \$COMMAND" \
      "Bearer test_token_abc123" "$PUT_CONTENTS"
    assert_contains "9a: PUT call uses PUT method" "X PUT " "$PUT_CONTENTS"

    # (W1093) after_doing PUTs twice: the early pre-commands capture plus the
    # post-commands refresh. Exactly two recorded calls proves the early PUT
    # was attempted before the section commands ran.
    PUT_CALL_COUNT=$(grep -c '^ARGS:' "$PUT_FIXTURE")
    assert_eq "9a: early capture + refresh make exactly two PUT calls" 2 "$PUT_CALL_COUNT"

    # D61: body must be a wrapped JSON object whose "changed_files" value is the
    # transport-encoded envelope {encoding: "base64", data: <string>} — NOT a
    # bare array (which lands at params['_json'] and persists as NULL) and NOT
    # raw diff text (which an edge filter could reject).
    PUT_BODY=$(extract_body "$PUT_FIXTURE")
    if [ -n "$PUT_BODY" ] && printf '%s' "$PUT_BODY" | jq -e '.changed_files.encoding == "base64" and (.changed_files.data | type) == "string"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: 9a: PUT body is the base64-encoded changed_files envelope"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 9a: PUT body is not the encoded envelope: $PUT_BODY"
      FAIL=$((FAIL + 1))
    fi

    # D61: the raw diff/path text MUST NOT appear in the wire body (it is
    # base64-encoded so an edge filter cannot misread it as an attack).
    if printf '%s' "$PUT_BODY" | grep -qF "tracked.txt"; then
      echo -e "  ${RED}FAIL${RESET}: 9a: raw path leaked into the wire body (should be base64-encoded)"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${RESET}: 9a: raw diff text is absent from the wire body (encoded)"
      PASS=$((PASS + 1))
    fi

    # D61: round-trip — re-encoding the snapshot the same way the hook does
    # reproduces the envelope's data field (portable: encode-only, no decode flag).
    EXPECTED_DATA=$(base64 < "$PUT_DIR/.stride-changed-files.json" 2>/dev/null | tr -d '\r\n')
    ACTUAL_DATA=$(printf '%s' "$PUT_BODY" | jq -r '.changed_files.data' 2>/dev/null)
    if [ -n "$EXPECTED_DATA" ] && [ "$ACTUAL_DATA" = "$EXPECTED_DATA" ]; then
      echo -e "  ${GREEN}PASS${RESET}: 9a: encoded data round-trips to the snapshot file content"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 9a: round-trip mismatch — data: $ACTUAL_DATA vs expected: $EXPECTED_DATA"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: 9a: PUT call was not made (no fixture written)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$PUT_DIR" "$STUB_DIR"

  # 9b: No Authorization header in $COMMAND → no PUT call
  NOTOK_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  NOTOK_FIXTURE="$NOTOK_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$NOTOK_FIXTURE" 0
  (
    setup_put_repo "$NOTOK_DIR" || exit 1
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete"}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ ! -f "$NOTOK_FIXTURE" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9b: no Bearer token in \$COMMAND → PUT skipped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9b: PUT was made despite missing token: $(cat "$NOTOK_FIXTURE")"
    FAIL=$((FAIL + 1))
  fi
  # Snapshot file must still be written for legacy --argjson cf consumers.
  if [ -f "$NOTOK_DIR/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9b: snapshot still written when PUT skipped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9b: snapshot was not written when PUT skipped"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOTOK_DIR" "$STUB_DIR"

  # 9c (D127): No TASK_ID in the env cache, but the /complete URL carries id 42 →
  # the upload targets 42 (env-cache-independent, the D127 fix). Before D127 this
  # skipped the PUT; making the upload depend on the env TASK_ID is the
  # empty-changed_files bug this fix removes.
  NOID_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  NOID_FIXTURE="$NOID_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$NOID_FIXTURE" 0
  (
    cd "$NOID_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
GITIGNORE
    echo "v1" > x.txt
    git add .gitignore x.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    echo "v2" > x.txt
    git add x.txt > /dev/null
    git commit -q -m "v2"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran"
```
STRIDE
    # No TASK_ID line — only TASK_BASE_REF.
    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer test_token\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if grep -qF '/api/tasks/42/changed_files' "$NOID_FIXTURE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${RESET}: 9c (D127): missing env TASK_ID → PUT still made, targeting the URL id (42)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9c (D127): expected PUT to /api/tasks/42/changed_files, fixture: $(cat "$NOID_FIXTURE" 2>/dev/null || echo NONE)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOID_DIR" "$STUB_DIR"

  # 9d: Empty snapshot ([]) still triggers a PUT (legitimate clear)
  EMPTY_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  EMPTY_FIXTURE="$EMPTY_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$EMPTY_FIXTURE" 0
  (
    cd "$EMPTY_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
GITIGNORE
    echo "v1" > y.txt
    git add .gitignore y.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Empty commit so capture_changed_files returns [].
    git commit -q --allow-empty -m "empty"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran"
```
STRIDE
    printf "TASK_ID='42'\nTASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$EMPTY_FIXTURE" ]; then
    EMPTY_CONTENTS=$(cat "$EMPTY_FIXTURE")
    assert_contains "9d: empty snapshot still triggers PUT" "X PUT " "$EMPTY_CONTENTS"
    # D61: an empty snapshot must still wrap as the transport-encoded envelope
    # whose data decodes back to an empty array (a legitimate clear), NOT a bare
    # empty array. Verified portably by re-encoding the snapshot file.
    EMPTY_BODY=$(extract_body "$EMPTY_FIXTURE")
    EMPTY_EXPECTED_DATA=$(base64 < "$EMPTY_DIR/.stride-changed-files.json" 2>/dev/null | tr -d '\r\n')
    EMPTY_ACTUAL_DATA=$(printf '%s' "$EMPTY_BODY" | jq -r '.changed_files.data' 2>/dev/null)
    if [ -n "$EMPTY_BODY" ] &&
       printf '%s' "$EMPTY_BODY" | jq -e '.changed_files.encoding == "base64"' > /dev/null 2>&1 &&
       [ -n "$EMPTY_EXPECTED_DATA" ] && [ "$EMPTY_ACTUAL_DATA" = "$EMPTY_EXPECTED_DATA" ]; then
      echo -e "  ${GREEN}PASS${RESET}: 9d: empty snapshot wraps as the base64-encoded envelope"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 9d: PUT body was not the encoded empty form: $EMPTY_BODY"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: 9d: PUT call was not made for empty snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$EMPTY_DIR" "$STUB_DIR"

  # 9e: PUT failure (stub curl exits 1) does not propagate — hook still exits 0
  FAIL_DIR=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  FAIL_FIXTURE="$FAIL_DIR/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$FAIL_FIXTURE" 1
  (
    cd "$FAIL_DIR" || exit 1
    setup_put_repo "$FAIL_DIR" > /dev/null 2>&1 || exit 1
    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""}}'
    echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  FAIL_EXIT=$?
  assert_exit "9e: PUT failure does not propagate (hook exits 0)" 0 "$FAIL_EXIT"
  if [ -f "$FAIL_DIR/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9e: snapshot file persists across failed PUT"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9e: snapshot file missing after failed PUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$FAIL_DIR" "$STUB_DIR"

  # 9f: HAS_JQ=false → PUT skipped (sourced unit test). Sourcing the hook
  # script with no PHASE arg short-circuits before the main flow runs, leaving
  # the function definitions in scope so we can call finalize_after_doing
  # directly with a forced HAS_JQ=false.
  NOJQ_DIR=$(mktemp -d)
  NOJQ_STUB=$(mktemp -d)
  NOJQ_FIXTURE="$NOJQ_DIR/curl-call.txt"
  make_curl_stub "$NOJQ_STUB" "$NOJQ_FIXTURE" 0
  (
    cd "$NOJQ_DIR" || exit 1
    printf '[]\n' > .stride-changed-files.json
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    HAS_JQ=false
    HOOK_NAME=after_doing
    TASK_ID=42
    COMMAND='curl -X PATCH https://stride.example.com/api/tasks/42/complete -H "Authorization: Bearer tok"'
    PROJECT_DIR="$NOJQ_DIR"
    PATH="$NOJQ_STUB:$PATH"
    finalize_after_doing
  )
  if [ ! -f "$NOJQ_FIXTURE" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 9f: HAS_JQ=false → PUT skipped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9f: PUT made with HAS_JQ=false: $(cat "$NOJQ_FIXTURE")"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOJQ_DIR" "$NOJQ_STUB"

  # 9g (D127): task_id_from_command extracts the id from a /complete or
  # /mark_reviewed URL and returns empty for the claim/next paths (no id) and for
  # a non-numeric segment. This is what lets the after_doing upload target the
  # correct task even when a hidden claim left a stale TASK_ID in the env cache
  # (the G321/D126 empty-changed_files root cause).
  TIDCMD_OUT=$(
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    printf '%s|%s|%s|%s|%s' \
      "$(task_id_from_command 'curl -X PATCH https://x/api/tasks/7777/complete -H h')" \
      "$(task_id_from_command 'curl -X PATCH https://x/api/tasks/42/mark_reviewed')" \
      "$(task_id_from_command 'curl -X POST https://x/api/tasks/claim')" \
      "$(task_id_from_command 'curl -s https://x/api/tasks/next')" \
      "$(task_id_from_command 'curl https://x/api/tasks/abc/complete')"
  )
  assert_eq "9g (D127): task_id_from_command reads /complete + /mark_reviewed ids, empty for claim/next/non-numeric" \
    "7777|42|||" "$TIDCMD_OUT"

  # 9h (D127): finalize_after_doing PUTs to the task id in the /complete URL, NOT
  # a stale env-cache TASK_ID. With TASK_ID=111111 (stale, prior task) and the
  # command completing /api/tasks/7777/complete, the changed_files PUT must target
  # 7777 — the fix for the empty-changed_files root cause.
  TGT_DIR=$(mktemp -d); TGT_STUB=$(mktemp -d)
  TGT_FIXTURE="$TGT_DIR/curl-call.txt"
  make_curl_stub "$TGT_STUB" "$TGT_FIXTURE" 0 200
  (
    setup_put_repo "$TGT_DIR" || exit 1
    cat > .stride_auth.md << 'AUTH'
- **API URL:** `https://tgt.example.com`
- **API Token:** `tok`
AUTH
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    HAS_JQ=true
    HOOK_NAME=after_doing
    TASK_ID=111111
    COMMAND='curl -X PATCH https://tgt.example.com/api/tasks/7777/complete -H "Authorization: Bearer tok"'
    PROJECT_DIR="$TGT_DIR"
    PATH="$TGT_STUB:$PATH"
    finalize_after_doing
  ) > /dev/null 2>&1
  if grep -qF '/api/tasks/7777/changed_files' "$TGT_FIXTURE" 2>/dev/null \
     && ! grep -qF '/api/tasks/111111/changed_files' "$TGT_FIXTURE" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${RESET}: 9h (D127): finalize PUTs to the /complete URL task id (7777), not the stale env TASK_ID (111111)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 9h (D127): PUT did not target 7777. Fixture: $(cat "$TGT_FIXTURE" 2>/dev/null)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$TGT_DIR" "$TGT_STUB"
fi

# ============================================================
# Test Group 10: D54 changed_files credential resolution
# ============================================================
# resolve_stride_api_url / resolve_stride_api_token read $PROJECT_DIR/.stride_auth.md
# as the PRIMARY source (production "**API Token:**" line, deliberately NOT the
# "**Local API Token:**" line), falling back to the $COMMAND literals. The token
# must never be logged. Sourcing the hook script with no PHASE defines the
# functions without running the main flow (see the early-return guard).
echo ""
echo "=== Test Group 10: D54 credential resolution ==="

# 10a: auth-file primary — resolvers return the values from .stride_auth.md
D54_DIR=$(mktemp -d)
cat > "$D54_DIR/.stride_auth.md" << 'AUTH'
# Stride API Authentication
- **API URL:** `https://www.stridelikeaboss.com`
- **Local API Token:** `stride_dev_LOCALONLYTOKEN`
- **API Token:** `stride_dev_PRODUCTIONTOKEN`
AUTH
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$D54_DIR"; COMMAND=''
  resolve_stride_api_token
)
assert_eq "10a: token resolved from .stride_auth.md (production line)" \
  "stride_dev_PRODUCTIONTOKEN" "$RESULT"
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$D54_DIR"; COMMAND=''
  resolve_stride_api_url
)
assert_eq "10a: URL resolved from .stride_auth.md" \
  "https://www.stridelikeaboss.com" "$RESULT"

# 10b: API-Token-vs-Local discrimination — never the Local API Token value
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$D54_DIR"; COMMAND=''
  resolve_stride_api_token
)
if [ "$RESULT" = "stride_dev_LOCALONLYTOKEN" ]; then
  echo -e "  ${RED}FAIL${RESET}: 10b: resolved the Local API Token instead of the production token"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 10b: Local API Token line is not resolved"
  PASS=$((PASS + 1))
fi
rm -rf "$D54_DIR"

# 10c: only the Local API Token line present + no $COMMAND → empty (never Local)
LOCAL_DIR=$(mktemp -d)
cat > "$LOCAL_DIR/.stride_auth.md" << 'AUTH'
- **Local API Token:** `stride_dev_LOCALONLYTOKEN`
AUTH
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$LOCAL_DIR"; COMMAND=''
  resolve_stride_api_token
)
assert_eq "10c: only Local API Token present → empty token" "" "$RESULT"
rm -rf "$LOCAL_DIR"

# 10d: no auth file → fall back to the $COMMAND literals
NOAUTH_DIR=$(mktemp -d)
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$NOAUTH_DIR"
  COMMAND='curl -X PATCH https://stride.example.com/api/tasks/42/complete -H "Authorization: Bearer cmd_fallback_token"'
  resolve_stride_api_token
)
assert_eq "10d: token falls back to \$COMMAND literal" "cmd_fallback_token" "$RESULT"
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$NOAUTH_DIR"
  COMMAND='curl -X PATCH https://stride.example.com/api/tasks/42/complete -H "Authorization: Bearer cmd_fallback_token"'
  resolve_stride_api_url
)
assert_eq "10d: URL falls back to \$COMMAND literal" "https://stride.example.com" "$RESULT"
rm -rf "$NOAUTH_DIR"

# 10e: shell-variable command + NO auth file → both empty (PUT silently skipped,
# since finalize_after_doing gates on non-empty URL AND token)
SHELLVAR_DIR=$(mktemp -d)
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$SHELLVAR_DIR"
  COMMAND='curl -X PATCH "$STRIDE_API_URL/api/tasks/42/complete" -H "Authorization: Bearer $STRIDE_API_TOKEN"'
  printf '%s|%s' "$(resolve_stride_api_url)" "$(resolve_stride_api_token)"
)
assert_eq "10e: shell-variable command + no auth file → no URL/token (PUT skipped)" "|" "$RESULT"
rm -rf "$SHELLVAR_DIR"

# 10f: shell-variable command + auth file PRESENT → auth file wins (PUT proceeds)
SHELLVAR_AUTH_DIR=$(mktemp -d)
cat > "$SHELLVAR_AUTH_DIR/.stride_auth.md" << 'AUTH'
- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `stride_dev_PRODUCTIONTOKEN`
AUTH
RESULT=$(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$SHELLVAR_AUTH_DIR"
  COMMAND='curl -X PATCH "$STRIDE_API_URL/api/tasks/42/complete" -H "Authorization: Bearer $STRIDE_API_TOKEN"'
  printf '%s|%s' "$(resolve_stride_api_url)" "$(resolve_stride_api_token)"
)
assert_eq "10f: shell-variable command + auth file → auth-file URL+token win" \
  "https://www.stridelikeaboss.com|stride_dev_PRODUCTIONTOKEN" "$RESULT"
rm -rf "$SHELLVAR_AUTH_DIR"

# 10g: no-token-logging — the resolver prints the token on stdout (consumed by
# the caller) but must NEVER write it to stderr, even in error paths.
LOG_DIR=$(mktemp -d)
cat > "$LOG_DIR/.stride_auth.md" << 'AUTH'
- **API Token:** `stride_dev_SECRETTOKEN`
AUTH
LOG_STDERR=$(mktemp)
(
  # shellcheck disable=SC1090
  source "$HOOK_SCRIPT" 2>/dev/null || true
  PROJECT_DIR="$LOG_DIR"; COMMAND=''
  resolve_stride_api_token
) > /dev/null 2>"$LOG_STDERR"
if grep -q 'stride_dev_SECRETTOKEN' "$LOG_STDERR"; then
  echo -e "  ${RED}FAIL${RESET}: 10g: token leaked to stderr"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: 10g: token not logged to stderr"
  PASS=$((PASS + 1))
fi
rm -f "$LOG_STDERR"; rm -rf "$LOG_DIR"

# ============================================================
# Test Group 11: after_doing early snapshot capture (W1093)
# ============================================================
# run_stride_section must call finalize_after_doing BEFORE the command loop
# when the GLOBAL HOOK_NAME is after_doing, so the hook timeout cannot kill the
# process before the diff snapshot is written. The post-loop call is kept as a
# refresh. Network safety: TASK_ID is never set and no .stride_auth.md exists in
# these fixtures, so finalize_after_doing skips the curl PUT entirely (it
# requires TASK_ID plus a resolvable URL and token before touching the network).
echo ""
echo "=== Test Group 11: after_doing early snapshot capture (W1093) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 11 requires both"
else
  # Helper: seed a git repo whose working tree differs from the printed base
  # ref by one tracked file (tracked.txt v1 -> v2). Prints the base ref.
  w1093_seed_repo() {
    local _dir="$1"
    (
      cd "$_dir" || exit 1
      git init -q
      git config user.email "test@test.local"
      git config user.name "Test"
      cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
early-snapshot.json
GITIGNORE
      echo "v1" > tracked.txt
      git add .gitignore tracked.txt > /dev/null
      git commit -q -m "v1"
      git rev-parse HEAD
      echo "v2" > tracked.txt
      git add tracked.txt > /dev/null
      git commit -q -m "v2"
    )
  }

  # 11a: early-capture ordering — the FIRST section command finds
  # .stride-changed-files.json already on disk and copies it aside.
  W1093_DIR_A=$(mktemp -d)
  W1093_BASE_A=$(w1093_seed_repo "$W1093_DIR_A")
  cat > "$W1093_DIR_A/.stride.md" << 'STRIDE'
## after_doing
```bash
cp .stride-changed-files.json early-snapshot.json
```
STRIDE
  W1093_OUT_A=$(
    cd "$W1093_DIR_A" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_A/.stride.md"
    PROJECT_DIR="$W1093_DIR_A"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    TASK_BASE_REF="$W1093_BASE_A"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_A=$?
  assert_exit "11a: after_doing section succeeds with early capture" 0 "$W1093_RC_A"
  assert_contains "11a: structured success JSON emitted" '"status": "success"' "$W1093_OUT_A"
  if jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' \
    "$W1093_DIR_A/early-snapshot.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 11a: snapshot existed (populated) BEFORE first section command ran"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 11a: first section command did not find a populated snapshot"
    FAIL=$((FAIL + 1))
  fi
  # stdout contract: the early capture must leak nothing onto stdout — the
  # captured output must be exactly one JSON document (the success JSON).
  if printf '%s' "$W1093_OUT_A" | jq -es 'length == 1 and .[0].hook == "after_doing"' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 11a: stdout is exactly the structured success JSON (early capture is silent)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 11a: stdout contains more than the success JSON: $W1093_OUT_A"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_A"

  # 11b: post-commands refresh — a section command modifies a tracked file;
  # the final snapshot must include that change while the early copy must not.
  W1093_DIR_B=$(mktemp -d)
  W1093_BASE_B=$(w1093_seed_repo "$W1093_DIR_B")
  cat > "$W1093_DIR_B/.stride.md" << 'STRIDE'
## after_doing
```bash
cp .stride-changed-files.json early-snapshot.json
echo "v3" > tracked.txt
```
STRIDE
  W1093_OUT_B=$(
    cd "$W1093_DIR_B" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_B/.stride.md"
    PROJECT_DIR="$W1093_DIR_B"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    TASK_BASE_REF="$W1093_BASE_B"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_B=$?
  assert_exit "11b: after_doing section with file-modifying command succeeds" 0 "$W1093_RC_B"
  W1093_EARLY_DIFF=$(jq -r '.[] | select(.path == "tracked.txt") | .diff' \
    "$W1093_DIR_B/early-snapshot.json" 2>/dev/null)
  W1093_FINAL_DIFF=$(jq -r '.[] | select(.path == "tracked.txt") | .diff' \
    "$W1093_DIR_B/.stride-changed-files.json" 2>/dev/null)
  if printf '%s' "$W1093_EARLY_DIFF" | grep -qF '+v3'; then
    echo -e "  ${RED}FAIL${RESET}: 11b: early snapshot already contains +v3 (capture not early)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 11b: early snapshot predates the section command's change"
    PASS=$((PASS + 1))
  fi
  if printf '%s' "$W1093_FINAL_DIFF" | grep -qF '+v3'; then
    echo -e "  ${GREEN}PASS${RESET}: 11b: post-commands refresh re-captured the section command's change"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 11b: final snapshot missing +v3 (refresh removed or skipped)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_B"

  # 11c: GLOBAL HOOK_NAME gate — running the after_goal SECTION while the
  # global HOOK_NAME is after_review must leave no snapshot (pitfall: the
  # gate is $HOOK_NAME, not the _section argument).
  W1093_DIR_C=$(mktemp -d)
  W1093_BASE_C=$(w1093_seed_repo "$W1093_DIR_C")
  cat > "$W1093_DIR_C/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "after_goal ran"
```
STRIDE
  W1093_OUT_C=$(
    cd "$W1093_DIR_C" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_C/.stride.md"
    PROJECT_DIR="$W1093_DIR_C"
    HAS_JQ=true
    HOOK_NAME="after_review"
    TASK_BASE_REF="$W1093_BASE_C"
    run_stride_section "after_goal" 2>/dev/null
  )
  W1093_RC_C=$?
  assert_exit "11c: after_goal section under HOOK_NAME=after_review succeeds" 0 "$W1093_RC_C"
  assert_contains "11c: structured success JSON references after_goal" '"hook": "after_goal"' "$W1093_OUT_C"
  if [ ! -f "$W1093_DIR_C/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 11c: no snapshot written when HOOK_NAME is not after_doing"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 11c: snapshot written despite HOOK_NAME=after_review (gate broken)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_C"

  # 11d: failing section command — structured failed JSON and return 2 are
  # preserved, with the early snapshot already on disk (the whole point of
  # W1093: the snapshot survives a gate failure or timeout).
  W1093_DIR_D=$(mktemp -d)
  W1093_BASE_D=$(w1093_seed_repo "$W1093_DIR_D")
  cat > "$W1093_DIR_D/.stride.md" << 'STRIDE'
## after_doing
```bash
bash -c 'exit 7'
```
STRIDE
  W1093_OUT_D=$(
    cd "$W1093_DIR_D" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_D/.stride.md"
    PROJECT_DIR="$W1093_DIR_D"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    TASK_BASE_REF="$W1093_BASE_D"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_D=$?
  assert_exit "11d: failing after_doing command still returns 2" 2 "$W1093_RC_D"
  assert_contains "11d: structured failed JSON emitted" '"status": "failed"' "$W1093_OUT_D"
  assert_contains "11d: failed JSON carries exit_code 7" '"exit_code": 7' "$W1093_OUT_D"
  if jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' \
    "$W1093_DIR_D/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 11d: early snapshot survives a failed quality gate"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 11d: snapshot missing or wrong after failed gate"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_D"

  # 11e: best-effort — non-repo dir with TASK_BASE_REF unset must still write
  # a [] snapshot and must NOT block the gate (early capture is never fatal).
  W1093_DIR_E=$(mktemp -d)
  cat > "$W1093_DIR_E/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "gate ran"
```
STRIDE
  W1093_OUT_E=$(
    cd "$W1093_DIR_E" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    STRIDE_MD="$W1093_DIR_E/.stride.md"
    PROJECT_DIR="$W1093_DIR_E"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    run_stride_section "after_doing" 2>/dev/null
  )
  W1093_RC_E=$?
  assert_exit "11e: non-repo early capture does not block the gate" 0 "$W1093_RC_E"
  assert_contains "11e: structured success JSON emitted" '"status": "success"' "$W1093_OUT_E"
  if jq -e 'type == "array" and length == 0' \
    "$W1093_DIR_E/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 11e: degraded capture wrote best-effort [] snapshot"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 11e: expected [] snapshot in non-repo dir"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$W1093_DIR_E"
fi

# ============================================================
# Test Group 12: changed_files upload self-heal (W1094)
# ============================================================
# finalize_after_doing records each PUT outcome in .stride-diff-upload-state
# (task id + HTTP code only); the before_review path verifies that state on a
# fresh PostToolUse budget and re-captures + re-PUTs when the state is missing,
# names a different task, or recorded a non-2xx. The state file is cleaned at
# the before_doing claim refresh and the after_review cleanup. Network safety:
# every test stubs curl on PATH (or supplies no TASK_ID), so no real network is
# reachable. Reuses the Group 9 helpers (make_curl_stub, setup_put_repo).
echo ""
echo "=== Test Group 12: changed_files upload self-heal (W1094) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 12 requires both (reuses Group 9 helpers)"
else
  # (D119) A parseable /complete response (no after_goal entry) so the D118 fast
  # path in route_after_goal answers "not armed" without a D119 fresh call —
  # isolating these changed_files self-heal assertions from the after_goal curl
  # path (whose after_goal_status GET would otherwise skew the PUT-count stubs).
  W1094_COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""},"tool_response":{"stdout":"{\"data\":{\"id\":42},\"hooks\":[{\"name\":\"before_review\"}]}"}}'

  # 12a: finalize_after_doing records task id + mocked 2xx in the state file
  # after the pre-path PUTs, and the state file carries no credentials.
  SH_DIR_A=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_A="$SH_DIR_A/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_A" 0 200
  (
    setup_put_repo "$SH_DIR_A" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$SH_DIR_A/.stride-diff-upload-state" ]; then
    SH_STATE_A=$(cat "$SH_DIR_A/.stride-diff-upload-state")
    assert_contains "12a: state file records the task id" "task_id=42" "$SH_STATE_A"
    assert_contains "12a: state file records the mocked 2xx" "http_code=200" "$SH_STATE_A"
    if echo "$SH_STATE_A" | grep -qE 'Bearer|https?://'; then
      echo -e "  ${RED}FAIL${RESET}: 12a: state file leaked a credential or URL: $SH_STATE_A"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${RESET}: 12a: state file carries no token or URL"
      PASS=$((PASS + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: 12a: state file was not written after the PUT attempt"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_A" "$STUB_DIR"

  # 12b: a non-2xx PUT outcome is recorded verbatim.
  SH_DIR_B=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  make_curl_stub "$STUB_DIR" "$SH_DIR_B/curl-call.txt" 0 500
  (
    setup_put_repo "$SH_DIR_B" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  SH_STATE_B=$(cat "$SH_DIR_B/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "12b: state file records the non-2xx code" "http_code=500" "$SH_STATE_B"
  rm -rf "$SH_DIR_B" "$STUB_DIR"

  # 12c: before_review retries when NO state file exists — re-captures the
  # snapshot against TASK_BASE_REF and PUTs it.
  SH_DIR_C=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_C="$SH_DIR_C/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_C" 0 200
  (
    setup_put_repo "$SH_DIR_C" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  SH_RC_C=$?
  assert_exit "12c: before_review with missing state exits 0" 0 "$SH_RC_C"
  if [ -f "$SH_FIXTURE_C" ]; then
    SH_CALLS_C=$(grep -c '^ARGS:' "$SH_FIXTURE_C")
    assert_eq "12c: missing state triggers exactly one retry PUT" 1 "$SH_CALLS_C"
    assert_contains "12c: retry PUT targets the changed_files route" \
      "https://stride.example.com/api/tasks/42/changed_files" "$(cat "$SH_FIXTURE_C")"
    assert_contains "12c: retry uses PUT method" "X PUT " "$(cat "$SH_FIXTURE_C")"
  else
    echo -e "  ${RED}FAIL${RESET}: 12c: no retry PUT was made for missing state"
    FAIL=$((FAIL + 1))
  fi
  if jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' \
    "$SH_DIR_C/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 12c: retry re-captured the snapshot against TASK_BASE_REF"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12c: retry did not re-capture the snapshot"
    FAIL=$((FAIL + 1))
  fi
  SH_STATE_C=$(cat "$SH_DIR_C/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "12c: retry outcome recorded for the current task" "task_id=42" "$SH_STATE_C"
  assert_contains "12c: retry outcome records the 2xx" "http_code=200" "$SH_STATE_C"
  rm -rf "$SH_DIR_C" "$STUB_DIR"

  # 12d: before_review does NOT re-upload when a 2xx is recorded for the
  # current task — and leaves the on-disk snapshot untouched.
  SH_DIR_D=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_D="$SH_DIR_D/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_D" 0 200
  (
    setup_put_repo "$SH_DIR_D" || exit 1
    printf 'task_id=42\nhttp_code=200\n' > .stride-diff-upload-state
    printf '[{"path":"stale.txt","diff":"marker"}]\n' > .stride-changed-files.json
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  SH_RC_D=$?
  assert_exit "12d: healthy-state before_review exits 0" 0 "$SH_RC_D"
  if [ ! -f "$SH_FIXTURE_D" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 12d: no re-upload on a recorded 2xx for the current task"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12d: re-uploaded despite healthy state: $(cat "$SH_FIXTURE_D")"
    FAIL=$((FAIL + 1))
  fi
  if jq -e '.[0].path == "stale.txt"' "$SH_DIR_D/.stride-changed-files.json" > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 12d: on-disk snapshot left untouched on healthy state"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12d: snapshot was overwritten despite healthy state"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_D" "$STUB_DIR"

  # 12e: a state file naming a DIFFERENT task id triggers the retry.
  SH_DIR_E=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_E="$SH_DIR_E/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_E" 0 200
  (
    setup_put_repo "$SH_DIR_E" || exit 1
    printf 'task_id=41\nhttp_code=200\n' > .stride-diff-upload-state
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ -f "$SH_FIXTURE_E" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 12e: stale task id in state triggers the retry PUT"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12e: no retry despite state naming a different task"
    FAIL=$((FAIL + 1))
  fi
  SH_STATE_E=$(cat "$SH_DIR_E/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "12e: state rewritten for the current task" "task_id=42" "$SH_STATE_E"
  rm -rf "$SH_DIR_E" "$STUB_DIR"

  # 12f: a recorded non-2xx for the current task triggers the retry.
  SH_DIR_F=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_F="$SH_DIR_F/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_F" 0 200
  (
    setup_put_repo "$SH_DIR_F" || exit 1
    printf 'task_id=42\nhttp_code=503\n' > .stride-diff-upload-state
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ -f "$SH_FIXTURE_F" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 12f: recorded non-2xx triggers the retry PUT"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12f: no retry despite recorded non-2xx"
    FAIL=$((FAIL + 1))
  fi
  SH_STATE_F=$(cat "$SH_DIR_F/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "12f: state updated to the retry's 2xx" "http_code=200" "$SH_STATE_F"
  rm -rf "$SH_DIR_F" "$STUB_DIR"

  # 12g: a FAILING retry warns on stderr in the existing style and never fails
  # the before_review hook.
  SH_DIR_G=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_ERR_G="$SH_DIR_G/stderr.txt"
  make_curl_stub "$STUB_DIR" "$SH_DIR_G/curl-call.txt" 0 500
  (
    setup_put_repo "$SH_DIR_G" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2> "$SH_ERR_G"
  )
  SH_RC_G=$?
  assert_exit "12g: failed retry never fails the before_review hook" 0 "$SH_RC_G"
  assert_contains "12g: failed retry warns in the existing stderr style" \
    "changed_files upload failed (HTTP 500) for task 42" "$(cat "$SH_ERR_G" 2>/dev/null)"
  SH_STATE_G=$(cat "$SH_DIR_G/.stride-diff-upload-state" 2>/dev/null)
  assert_contains "12g: failed retry outcome recorded" "http_code=500" "$SH_STATE_G"
  rm -rf "$SH_DIR_G" "$STUB_DIR"

  # 12h: the before_doing claim refresh removes a stale state file.
  SH_DIR_H=$(mktemp -d)
  cat > "$SH_DIR_H/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "claimed"
```
STRIDE
  printf 'task_id=41\nhttp_code=200\n' > "$SH_DIR_H/.stride-diff-upload-state"
  SH_CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W42\",\"title\":\"T\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}"}'
  (
    cd "$SH_DIR_H" || exit 1
    echo "$SH_CLAIM_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ ! -f "$SH_DIR_H/.stride-diff-upload-state" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 12h: claim refresh removes the previous task's upload state"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12h: stale upload state survived the claim refresh"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_H"

  # 12i: the after_review cleanup removes the state file.
  SH_DIR_I=$(mktemp -d)
  cat > "$SH_DIR_I/.stride.md" << 'STRIDE'
## after_review
```bash
echo "reviewed"
```
STRIDE
  printf 'task_id=42\nhttp_code=200\n' > "$SH_DIR_I/.stride-diff-upload-state"
  SH_REVIEW_JSON='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/mark_reviewed"}}'
  (
    cd "$SH_DIR_I" || exit 1
    echo "$SH_REVIEW_JSON" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ ! -f "$SH_DIR_I/.stride-diff-upload-state" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 12i: after_review cleanup removes the upload state"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12i: upload state survived the after_review cleanup"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$SH_DIR_I"

  # 12j: end-to-end pre then post — a healthy after_doing upload (early +
  # refresh = exactly 2 PUTs) is NOT repeated by the before_review pass.
  SH_DIR_J=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  SH_FIXTURE_J="$SH_DIR_J/curl-call.txt"
  make_curl_stub "$STUB_DIR" "$SH_FIXTURE_J" 0 200
  (
    setup_put_repo "$SH_DIR_J" || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  SH_CALLS_J=$(grep -c '^ARGS:' "$SH_FIXTURE_J" 2>/dev/null)
  assert_eq "12j: healthy pre-path upload is not repeated by before_review" 2 "$SH_CALLS_J"
  rm -rf "$SH_DIR_J" "$STUB_DIR"

  # 12k (W1658): before_review self-heal TERMINAL failure. When the LAST retry
  # PUT returns non-2xx, the hook surfaces a loud UNRESOLVED warning on stderr
  # (distinct from the per-attempt warning) AND marks the state file
  # `unresolved=yes` — so a definitively-lost diff is never silently swallowed.
  # The hook exit code is unchanged (the completion still succeeds).
  SH_DIR_K=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  make_curl_stub "$STUB_DIR" "$SH_DIR_K/curl-call.txt" 0 500
  SH_STDERR_K=$(
    setup_put_repo "$SH_DIR_K" > /dev/null 2>&1 || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post 2>&1 1>/dev/null
  )
  SH_RC_K=$(
    setup_put_repo "$SH_DIR_K" > /dev/null 2>&1 || exit 1
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_DIR:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
    echo $?
  )
  SH_STATE_K=$(cat "$SH_DIR_K/.stride-diff-upload-state" 2>/dev/null)
  assert_eq "12k (W1658): terminal self-heal failure never fails the hook" "0" "$SH_RC_K"
  if printf '%s' "$SH_STDERR_K" | grep -qF 'CHANGED_FILES UPLOAD UNRESOLVED'; then
    echo -e "  ${GREEN}PASS${RESET}: 12k (W1658): terminal self-heal failure prints a loud UNRESOLVED warning"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 12k (W1658): no loud UNRESOLVED warning on stderr: $SH_STDERR_K"
    FAIL=$((FAIL + 1))
  fi
  assert_contains "12k (W1658): state file marked unresolved on terminal failure" "unresolved=yes" "$SH_STATE_K"
  rm -rf "$SH_DIR_K" "$STUB_DIR"

  # 12l (W1658): a 2xx self-heal never emits the UNRESOLVED message (a
  # legitimately-empty diff that still PUTs 2xx takes the success path), and the
  # unresolved mark self-clears on a later success — record_diff_upload_state
  # truncates the state file, so a subsequent healthy PUT drops the marker.
  SH_DIR_L=$(mktemp -d)
  STUB_FAIL_L=$(mktemp -d)
  STUB_OK_L=$(mktemp -d)
  make_curl_stub "$STUB_FAIL_L" "$SH_DIR_L/curl-fail.txt" 0 500
  make_curl_stub "$STUB_OK_L" "$SH_DIR_L/curl-ok.txt" 0 200
  SH_STDERR_L=$(
    setup_put_repo "$SH_DIR_L" > /dev/null 2>&1 || exit 1
    # First before_review retry fails (500) → marks unresolved.
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_FAIL_L:$PATH" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
    # Second before_review retry succeeds (200) → overwrites state, clears mark.
    echo "$W1094_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$PWD" PATH="$STUB_OK_L:$PATH" bash "$HOOK_SCRIPT" post 2>&1 1>/dev/null
  )
  SH_STATE_L=$(cat "$SH_DIR_L/.stride-diff-upload-state" 2>/dev/null)
  if printf '%s' "$SH_STATE_L" | grep -qF 'unresolved=yes'; then
    echo -e "  ${RED}FAIL${RESET}: 12l (W1658): unresolved mark survived a later successful PUT: $SH_STATE_L"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 12l (W1658): a later 2xx PUT overwrites the state file and clears the unresolved mark"
    PASS=$((PASS + 1))
  fi
  if printf '%s' "$SH_STDERR_L" | grep -qF 'CHANGED_FILES UPLOAD UNRESOLVED'; then
    echo -e "  ${RED}FAIL${RESET}: 12l (W1658): a 2xx self-heal must not emit the UNRESOLVED message: $SH_STDERR_L"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 12l (W1658): a 2xx self-heal does not emit the UNRESOLVED message"
    PASS=$((PASS + 1))
  fi
  assert_contains "12l (W1658): state records the healthy 2xx after self-clear" "http_code=200" "$SH_STATE_L"
  rm -rf "$SH_DIR_L" "$STUB_FAIL_L" "$STUB_OK_L"
fi

# ============================================================
# Test Group 13: claim-time TASK_BASE_REF refresh + persisted-output
# fallback (W1086)
# ============================================================
# A claim always opens a new task window. The hook must refresh TASK_BASE_REF
# to current HEAD on every claim: from parseable stdout, from a persisted
# output file when stdout only carries a "saved to" notice, and — when no JSON
# is obtainable at all — by rewriting only the TASK_BASE_REF line while
# preserving the existing TASK_ identity lines. Non-claim hooks never touch it.
# Reuses the Group 9 helper setup_put_repo.
echo ""
echo "=== Test Group 13: claim TASK_BASE_REF refresh (W1086) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 13 requires both (reuses Group 9 helpers)"
else
  # 13a: inline stdout JSON (Copilot wrapper) writes the full cache with
  # TASK_BASE_REF equal to current HEAD.
  BR_DIR_A=$(mktemp -d)
  BR_CLAIM_A='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":42,\"identifier\":\"W42\",\"title\":\"Inline Task\",\"status\":\"in_progress\",\"complexity\":\"medium\",\"priority\":\"high\"}}","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_A" || exit 1
    echo "$BR_CLAIM_A" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_A=$(git -C "$BR_DIR_A" rev-parse HEAD)
  BR_CACHE_A=$(cat "$BR_DIR_A/.stride-env-cache" 2>/dev/null)
  assert_contains "13a: inline JSON writes the identifier" "TASK_IDENTIFIER='W42'" "$BR_CACHE_A"
  assert_contains "13a: inline JSON sets TASK_BASE_REF to current HEAD" "TASK_BASE_REF='$BR_HEAD_A'" "$BR_CACHE_A"
  rm -rf "$BR_DIR_A"

  # 13b: a persisted-output notice pointing at a readable file containing the
  # API JSON writes the full cache from the file content.
  BR_DIR_B=$(mktemp -d)
  BR_PERSIST_B=$(mktemp -d)
  BR_FILE_B="$BR_PERSIST_B/persisted.json"
  printf '{"data":{"id":77,"identifier":"W77","title":"Persisted Task","status":"in_progress","complexity":"medium","priority":"high"}}' > "$BR_FILE_B"
  BR_CLAIM_B=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s","stderr":"","interrupted":false}}' "$BR_FILE_B")
  (
    setup_put_repo "$BR_DIR_B" || exit 1
    echo "$BR_CLAIM_B" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_B=$(git -C "$BR_DIR_B" rev-parse HEAD)
  BR_CACHE_B=$(cat "$BR_DIR_B/.stride-env-cache" 2>/dev/null)
  assert_contains "13b: persisted file supplies the identifier" "TASK_IDENTIFIER='W77'" "$BR_CACHE_B"
  assert_contains "13b: persisted file path sets TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_B'" "$BR_CACHE_B"
  rm -rf "$BR_DIR_B" "$BR_PERSIST_B"

  # 13c: garbage stdout with no persisted file refreshes only TASK_BASE_REF,
  # preserves the prior TASK_ID line, and removes the stale snapshot.
  BR_DIR_C=$(mktemp -d)
  BR_CLAIM_C='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"this is not json at all","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_C" || exit 1
    printf '[{"path":"stale.txt","diff":"x"}]\n' > .stride-changed-files.json
    echo "$BR_CLAIM_C" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_C=$(git -C "$BR_DIR_C" rev-parse HEAD)
  BR_CACHE_C=$(cat "$BR_DIR_C/.stride-env-cache" 2>/dev/null)
  assert_contains "13c: garbage stdout preserves the prior TASK_ID" "TASK_ID='42'" "$BR_CACHE_C"
  assert_contains "13c: garbage stdout still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_C'" "$BR_CACHE_C"
  if [ ! -f "$BR_DIR_C/.stride-changed-files.json" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 13c: base-ref-only refresh removes the stale snapshot"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13c: stale snapshot survived the base-ref-only refresh"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$BR_DIR_C"

  # 13d: a persisted-output notice pointing at a missing file falls through to
  # the base-ref-only refresh (prior TASK_ID preserved, TASK_BASE_REF = HEAD).
  BR_DIR_D=$(mktemp -d)
  BR_PERSIST_D=$(mktemp -d)
  BR_CLAIM_D=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s/does-not-exist.json","stderr":"","interrupted":false}}' "$BR_PERSIST_D")
  (
    setup_put_repo "$BR_DIR_D" || exit 1
    echo "$BR_CLAIM_D" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_D=$(git -C "$BR_DIR_D" rev-parse HEAD)
  BR_CACHE_D=$(cat "$BR_DIR_D/.stride-env-cache" 2>/dev/null)
  assert_contains "13d: missing persisted file preserves the prior TASK_ID" "TASK_ID='42'" "$BR_CACHE_D"
  assert_contains "13d: missing persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_D'" "$BR_CACHE_D"
  rm -rf "$BR_DIR_D" "$BR_PERSIST_D"

  # 13e: a non-claim post invocation (complete URL) leaves TASK_BASE_REF
  # untouched at the previously-recorded base ref.
  BR_DIR_E=$(mktemp -d)
  BR_COMPLETE_E='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete"}}'
  (
    setup_put_repo "$BR_DIR_E" || exit 1
    echo "$BR_COMPLETE_E" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_BASE_E=$(grep -oE "TASK_BASE_REF='[^']*'" "$BR_DIR_E/.stride-env-cache" 2>/dev/null)
  BR_PUTBASE_E=$(git -C "$BR_DIR_E" rev-parse HEAD~1)
  assert_eq "13e: complete URL leaves TASK_BASE_REF at the prior base ref" "TASK_BASE_REF='$BR_PUTBASE_E'" "$BR_BASE_E"
  rm -rf "$BR_DIR_E"

  # 13f: garbage stdout in a non-git directory (rev-parse fails) never crashes
  # the hook and writes no cache.
  BR_DIR_F=$(mktemp -d)
  cat > "$BR_DIR_F/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "claimed"
```
STRIDE
  BR_CLAIM_F='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"not json","stderr":"","interrupted":false}}'
  OUTPUT=$(echo "$BR_CLAIM_F" | CLAUDE_PROJECT_DIR="$BR_DIR_F" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "13f: garbage stdout in a non-git dir exits 0" 0 "$EXIT_CODE"
  if [ ! -f "$BR_DIR_F/.stride-env-cache" ]; then
    echo -e "  ${GREEN}PASS${RESET}: 13f: no cache written when HEAD is unresolvable"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 13f: cache written despite unresolvable HEAD"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$BR_DIR_F"

  # 13g: a persisted file whose content is the harness preview text (not JSON)
  # falls through to the base-ref-only refresh.
  BR_DIR_G=$(mktemp -d)
  BR_PERSIST_G=$(mktemp -d)
  BR_FILE_G="$BR_PERSIST_G/preview.txt"
  printf '... (output truncated for preview) ...\nnot valid json\n' > "$BR_FILE_G"
  BR_CLAIM_G=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s","stderr":"","interrupted":false}}' "$BR_FILE_G")
  (
    setup_put_repo "$BR_DIR_G" || exit 1
    echo "$BR_CLAIM_G" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_G=$(git -C "$BR_DIR_G" rev-parse HEAD)
  BR_CACHE_G=$(cat "$BR_DIR_G/.stride-env-cache" 2>/dev/null)
  assert_contains "13g: non-JSON persisted file preserves the prior TASK_ID" "TASK_ID='42'" "$BR_CACHE_G"
  assert_contains "13g: non-JSON persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_G'" "$BR_CACHE_G"
  rm -rf "$BR_DIR_G" "$BR_PERSIST_G"

  # 13h: garbage stdout with NO pre-existing cache creates one containing only
  # TASK_BASE_REF (no TASK_ identity lines to preserve).
  BR_DIR_H=$(mktemp -d)
  BR_CLAIM_H='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"garbage","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_H" || exit 1
    rm -f .stride-env-cache
    echo "$BR_CLAIM_H" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_H=$(git -C "$BR_DIR_H" rev-parse HEAD)
  BR_CACHE_H=$(cat "$BR_DIR_H/.stride-env-cache" 2>/dev/null)
  assert_contains "13h: absent cache is created with TASK_BASE_REF at HEAD" "TASK_BASE_REF='$BR_HEAD_H'" "$BR_CACHE_H"
  if echo "$BR_CACHE_H" | grep -q '^TASK_ID='; then
    echo -e "  ${RED}FAIL${RESET}: 13h: invented a TASK_ID line with no source data"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 13h: no spurious TASK_ identity lines created"
    PASS=$((PASS + 1))
  fi
  rm -rf "$BR_DIR_H"

  # 13i: a persisted-output path containing spaces is recovered intact (the
  # notice may also wrap it in quotes). Guards the bash/ps1 parity contract.
  BR_DIR_I=$(mktemp -d)
  BR_PERSIST_I=$(mktemp -d)/"with space dir"
  mkdir -p "$BR_PERSIST_I"
  BR_FILE_I="$BR_PERSIST_I/persisted.json"
  printf '{"data":{"id":88,"identifier":"W88","title":"Spaced Task","status":"in_progress","complexity":"small","priority":"low"}}' > "$BR_FILE_I"
  BR_CLAIM_I=$(printf '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"Full output saved to: %s","stderr":"","interrupted":false}}' "$BR_FILE_I")
  (
    setup_put_repo "$BR_DIR_I" || exit 1
    echo "$BR_CLAIM_I" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_CACHE_I=$(cat "$BR_DIR_I/.stride-env-cache" 2>/dev/null)
  assert_contains "13i: persisted path with spaces is recovered" "TASK_IDENTIFIER='W88'" "$BR_CACHE_I"
  rm -rf "$BR_DIR_I" "$BR_PERSIST_I"

  # 13j (W1609): a claim whose stdout is truncated mid-JSON but which has a
  # present canonical response file recovers the FULL task JSON from the file —
  # TASK_IDENTIFIER comes from the file and TASK_BASE_REF is refreshed to HEAD.
  # Without the shared file-first resolver the claim would degrade to a
  # base-ref-only refresh and lose task identity.
  BR_DIR_J2=$(mktemp -d)
  BR_CLAIM_J2='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":609,\"identif","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_J2" || exit 1
    mkdir -p .stride
    printf '{"data":{"id":609,"identifier":"W609","title":"File Task","status":"in_progress","complexity":"medium","priority":"high"}}' > .stride/.last-api-response.json
    echo "$BR_CLAIM_J2" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_HEAD_J2=$(git -C "$BR_DIR_J2" rev-parse HEAD)
  BR_CACHE_J2=$(cat "$BR_DIR_J2/.stride-env-cache" 2>/dev/null)
  assert_contains "13j: truncated claim recovers the identifier from the canonical file" "TASK_IDENTIFIER='W609'" "$BR_CACHE_J2"
  assert_contains "13j: truncated claim still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF='$BR_HEAD_J2'" "$BR_CACHE_J2"
  rm -rf "$BR_DIR_J2"

  # 13k (W1609): a valid claim stdout is captured to the canonical response file
  # so later lifecycle hooks (whose own stdout the harness may truncate) can read it.
  BR_DIR_K2=$(mktemp -d)
  BR_CLAIM_K2='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":610,\"identifier\":\"W610\",\"title\":\"Cap Task\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_K2" || exit 1
    echo "$BR_CLAIM_K2" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_RESP_K2=$(cat "$BR_DIR_K2/.stride/.last-api-response.json" 2>/dev/null)
  assert_contains "13k: valid claim stdout is captured to the canonical response file" '"identifier":"W610"' "$BR_RESP_K2"
  rm -rf "$BR_DIR_K2"

  # 13l (W1609): a stale canonical file from a prior call does NOT shadow a valid
  # current claim stdout — the capture overwrites it first, so the env cache
  # reflects the CURRENT claim, not the stale file (no staleness regression).
  BR_DIR_L2=$(mktemp -d)
  BR_CLAIM_L2='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":611,\"identifier\":\"W611\",\"title\":\"Fresh\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}","stderr":"","interrupted":false}}'
  (
    setup_put_repo "$BR_DIR_L2" || exit 1
    mkdir -p .stride
    printf '{"data":{"id":999,"identifier":"W999","title":"Stale","status":"in_progress","complexity":"large","priority":"high"}}' > .stride/.last-api-response.json
    echo "$BR_CLAIM_L2" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  BR_CACHE_L2=$(cat "$BR_DIR_L2/.stride-env-cache" 2>/dev/null)
  assert_contains "13l: current valid claim overwrites the stale canonical file" "TASK_IDENTIFIER='W611'" "$BR_CACHE_L2"
  if echo "$BR_CACHE_L2" | grep -q "W999"; then
    echo -e "  ${RED}FAIL${RESET}: 13l: stale file's identifier leaked into the env cache"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 13l: stale identifier did not leak into the env cache"
    PASS=$((PASS + 1))
  fi
  rm -rf "$BR_DIR_L2"

  # 13m (W1609): capture_changed_files never includes anything under the root
  # .stride/ state dir (the canonical response file and orchestrator marker live
  # there) even in a repo that forgot to gitignore it — a real change is still captured.
  CF_DIR2=$(mktemp -d)
  CF_OUT2=$(
    cd "$CF_DIR2" || exit 99
    git init -q; git config user.email t@t.local; git config user.name t
    echo base > a.txt; git add a.txt; git commit -qm base > /dev/null 2>&1
    CF_BASE2=$(git rev-parse HEAD)
    echo changed > a.txt
    mkdir -p .stride; printf '{"data":{"id":1}}' > .stride/.last-api-response.json
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$CF_DIR2"
    HAS_JQ=true
    capture_changed_files "$CF_BASE2" 2>/dev/null
  )
  if echo "$CF_OUT2" | grep -q 'last-api-response.json'; then
    echo -e "  ${RED}FAIL${RESET}: 13m: .stride/ file leaked into changed_files"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 13m: .stride/ state dir excluded from changed_files"
    PASS=$((PASS + 1))
  fi
  assert_contains "13m: a real changed file is still captured" "a.txt" "$CF_OUT2"
  rm -rf "$CF_DIR2"
fi

# ============================================================
# Test Group 14: per-hook timeout enforcement (W1513)
# ============================================================
echo ""
echo "=== Test Group 14: per-hook timeout enforcement (W1513) ==="

# 14a-14d: _hook_timeout_secs maps each routed section to its documented budget
# (after_doing 120s; everything else, including unknown sections, 60s).
TO_MAP=$(
  source "$HOOK_SCRIPT" 2>/dev/null
  printf '%s %s %s %s %s\n' \
    "$(_hook_timeout_secs before_doing)" \
    "$(_hook_timeout_secs after_doing)" \
    "$(_hook_timeout_secs before_review)" \
    "$(_hook_timeout_secs after_goal)" \
    "$(_hook_timeout_secs some_unknown_section)"
)
assert_eq "14a: per-hook budgets (before/after_doing/before_review/after_goal/unknown)" \
  "60 120 60 60 60" "$TO_MAP"

# 14b: STRIDE_HOOK_TIMEOUT_SECS overrides every section when a positive integer.
TO_OVERRIDE=$(
  source "$HOOK_SCRIPT" 2>/dev/null
  STRIDE_HOOK_TIMEOUT_SECS=5 _hook_timeout_secs after_doing
)
assert_eq "14b: positive override wins over the default budget" "5" "$TO_OVERRIDE"

# 14c: a non-numeric override is ignored; the documented default applies.
TO_BADOVERRIDE=$(
  source "$HOOK_SCRIPT" 2>/dev/null
  STRIDE_HOOK_TIMEOUT_SECS=abc _hook_timeout_secs after_doing
)
assert_eq "14c: non-numeric override falls back to the default budget" "120" "$TO_BADOVERRIDE"

# 14d: a zero override is ignored (must be a positive integer).
TO_ZEROOVERRIDE=$(
  source "$HOOK_SCRIPT" 2>/dev/null
  STRIDE_HOOK_TIMEOUT_SECS=0 _hook_timeout_secs before_doing
)
assert_eq "14d: zero override falls back to the default budget" "60" "$TO_ZEROOVERRIDE"

# 14e: _resolve_timeout_bin resolves cleanly to empty when no timeout utility is
# on PATH — the documented graceful degradation (no enforcement, no error).
TO_NOBIN=$(
  source "$HOOK_SCRIPT" 2>/dev/null
  PATH="" _resolve_timeout_bin 2>/dev/null
)
assert_eq "14e: no timeout utility on PATH resolves to empty (clean degrade)" "" "$TO_NOBIN"

# The remaining cases need a real timeout utility to exercise enforcement.
if [ -z "$(command -v timeout || command -v gtimeout)" ]; then
  echo "  SKIP: 14f-14h require a timeout/gtimeout utility (none found)"
else
  # 14f: a command that outlasts its (overridden 1s) budget is terminated and
  # reported via the existing failed-JSON shape — exit_code 124, a self-
  # describing timeout note, and (after_doing/pre) the exit-2 blocking semantic.
  TO_E2E_PROJ="$TMPDIR_TEST/timeout-e2e"
  mkdir -p "$TO_E2E_PROJ"
  cat > "$TO_E2E_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
sleep 5
```
STRIDE
  TO_COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
  TO_E2E_OUT=$(echo "$TO_COMPLETE_JSON" | \
    STRIDE_HOOK_TIMEOUT_SECS=1 CLAUDE_PROJECT_DIR="$TO_E2E_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
  TO_E2E_RC=$?
  assert_exit "14f: timed-out after_doing blocks completion (exit 2)" 2 "$TO_E2E_RC"
  assert_contains "14f: failed-JSON carries the timeout exit_code 124" '"exit_code": 124' "$TO_E2E_OUT"
  assert_contains "14f: failure names the per-hook timeout budget" "per-hook timeout budget" "$TO_E2E_OUT"

  # 14g: a fast command well under the (overridden) budget still passes cleanly.
  TO_OK_PROJ="$TMPDIR_TEST/timeout-ok"
  mkdir -p "$TO_OK_PROJ"
  cat > "$TO_OK_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "fast_command_ran"
```
STRIDE
  TO_OK_OUT=$(echo "$TO_COMPLETE_JSON" | \
    STRIDE_HOOK_TIMEOUT_SECS=5 CLAUDE_PROJECT_DIR="$TO_OK_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
  TO_OK_RC=$?
  assert_exit "14g: fast command under budget exits 0" 0 "$TO_OK_RC"
  assert_contains "14g: fast command ran" "fast_command_ran" "$TO_OK_OUT"

  # 14h: degradation — with the resolver stubbed empty, the executor still runs
  # the section to success via the in-process eval fallback (no enforcement, no
  # error). Proves AC3 for the executor, independent of host tooling.
  TO_DEGRADE_PROJ="$TMPDIR_TEST/timeout-degrade"
  mkdir -p "$TO_DEGRADE_PROJ"
  cat > "$TO_DEGRADE_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "degraded_path_ran"
```
STRIDE
  TO_DEGRADE_OUT=$(
    cd "$TO_DEGRADE_PROJ" || exit 99
    source "$HOOK_SCRIPT" 2>/dev/null
    _resolve_timeout_bin() { printf ''; }
    STRIDE_MD="$TO_DEGRADE_PROJ/.stride.md"
    PROJECT_DIR="$TO_DEGRADE_PROJ"
    HAS_JQ=true
    HOOK_NAME="after_doing"
    run_stride_section "after_doing" 2>/dev/null
  )
  TO_DEGRADE_RC=$?
  assert_exit "14h: eval fallback (no timeout util) succeeds" 0 "$TO_DEGRADE_RC"
  assert_contains "14h: eval fallback ran the command" "degraded_path_ran" "$TO_DEGRADE_OUT"
fi

# ============================================================
# Test Group 15: millisecond duration reporting (W1514)
# ============================================================
echo ""
echo "=== Test Group 15: millisecond duration reporting (W1514) ==="

# 15a: _now_ms returns an all-digit epoch-millisecond value of the right
# magnitude (13 digits in the 2020s).
NOW_MS_A=$(source "$HOOK_SCRIPT" 2>/dev/null; _now_ms)
case "$NOW_MS_A" in
  '' | *[!0-9]*)
    echo -e "  ${RED}FAIL${RESET}: 15a: _now_ms not all digits ($NOW_MS_A)"; FAIL=$((FAIL + 1)) ;;
  *)
    if [ "${#NOW_MS_A}" -ge 12 ]; then
      echo -e "  ${GREEN}PASS${RESET}: 15a: _now_ms returns epoch-ms all digits (${#NOW_MS_A} digits)"; PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 15a: _now_ms magnitude too small ($NOW_MS_A)"; FAIL=$((FAIL + 1))
    fi ;;
esac

# 15b: _now_ms advances with sub-second fidelity across a 0.15s sleep — proves
# the active source is high-resolution, not the whole-second last resort (which
# would report 0 or 1000).
NOW_MS_DELTA=$(source "$HOOK_SCRIPT" 2>/dev/null; a=$(_now_ms); sleep 0.15; b=$(_now_ms); echo $((b - a)))
if [ "$NOW_MS_DELTA" -ge 100 ] && [ "$NOW_MS_DELTA" -lt 1000 ]; then
  echo -e "  ${GREEN}PASS${RESET}: 15b: _now_ms tracks a 0.15s sleep with ms fidelity (${NOW_MS_DELTA}ms)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${RESET}: 15b: _now_ms delta ${NOW_MS_DELTA}ms is not sub-second high-resolution"; FAIL=$((FAIL + 1))
fi

# 15c: perl fallback — with GNU `date +%s%N` forced to fail and EPOCHREALTIME
# unset, _now_ms still returns an all-digit epoch-ms value via Time::HiRes. This
# is the path a stock-BSD-date (macOS without coreutils) platform takes.
if command -v perl > /dev/null 2>&1; then
  NOW_MS_PERL=$(
    source "$HOOK_SCRIPT" 2>/dev/null
    unset EPOCHREALTIME
    date() { return 1; }   # neutralize the GNU date +%s%N branch
    _now_ms
  )
  case "$NOW_MS_PERL" in
    '' | *[!0-9]*)
      echo -e "  ${RED}FAIL${RESET}: 15c: perl fallback not all digits ($NOW_MS_PERL)"; FAIL=$((FAIL + 1)) ;;
    *)
      if [ "${#NOW_MS_PERL}" -ge 12 ]; then
        echo -e "  ${GREEN}PASS${RESET}: 15c: perl fallback yields epoch-ms when date +%N is unavailable"; PASS=$((PASS + 1))
      else
        echo -e "  ${RED}FAIL${RESET}: 15c: perl fallback magnitude wrong ($NOW_MS_PERL)"; FAIL=$((FAIL + 1))
      fi ;;
  esac
else
  echo "  SKIP: 15c perl fallback (perl not available)"
fi

# 15d: the success JSON emits an integer duration_ms and NO lingering
# duration_seconds field.
if command -v jq > /dev/null 2>&1; then
  MS_PROJ="$TMPDIR_TEST/duration-ms"
  mkdir -p "$MS_PROJ"
  cat > "$MS_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "ms_test"
```
STRIDE
  MS_OUT=$(echo "$COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$MS_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
  if echo "$MS_OUT" | jq -e '.duration_ms | type == "number"' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 15d: success JSON has integer duration_ms"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 15d: success JSON missing numeric duration_ms: $MS_OUT"; FAIL=$((FAIL + 1))
  fi
  if echo "$MS_OUT" | jq -e 'has("duration_seconds")' > /dev/null 2>&1; then
    echo -e "  ${RED}FAIL${RESET}: 15d: lingering duration_seconds field in success JSON"; FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 15d: no lingering duration_seconds field"; PASS=$((PASS + 1))
  fi
else
  echo "  SKIP: 15d duration_ms JSON assertion (jq not available)"
fi

# ============================================================
# Test Group 16: backslash line-continuation in the parser (W1515)
# ============================================================
echo ""
echo "=== Test Group 16: backslash line-continuation (W1515) ==="

CONT_COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'

# 16a: a command split across lines with a trailing backslash is joined and runs
# as ONE command.
CONT_PROJ="$TMPDIR_TEST/continuation-join"
mkdir -p "$CONT_PROJ"
cat > "$CONT_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo one \
two three
```
STRIDE
CONT_OUT=$(echo "$CONT_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$CONT_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
CONT_RC=$?
assert_exit "16a: continuation hook exits 0" 0 "$CONT_RC"
assert_contains "16a: joined command output is one line" "one two three" "$CONT_OUT"
if command -v jq > /dev/null 2>&1; then
  if echo "$CONT_OUT" | jq -e '.commands_completed | length == 1' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 16a: continued lines collapse to a single command"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 16a: expected 1 joined command: $CONT_OUT"; FAIL=$((FAIL + 1))
  fi
  if echo "$CONT_OUT" | jq -e '.commands_completed[0] == "echo one two three"' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 16a: joined command text is exactly the continuation"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 16a: joined command text wrong: $CONT_OUT"; FAIL=$((FAIL + 1))
  fi
fi

# 16b: a standalone comment after a completed command is still skipped (not
# glued to the prior continued command), and blank/comment handling survives.
CONT_CMT_PROJ="$TMPDIR_TEST/continuation-comment"
mkdir -p "$CONT_CMT_PROJ"
cat > "$CONT_CMT_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo alpha \
beta
# a standalone comment
echo gamma
```
STRIDE
CONT_CMT_OUT=$(echo "$CONT_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$CONT_CMT_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
assert_contains "16b: continued command ran" "alpha beta" "$CONT_CMT_OUT"
assert_contains "16b: following command ran" "gamma" "$CONT_CMT_OUT"
if command -v jq > /dev/null 2>&1; then
  if echo "$CONT_CMT_OUT" | jq -e '.commands_completed | length == 2' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 16b: two commands (comment skipped, not glued)"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 16b: expected 2 commands, comment leaked: $CONT_CMT_OUT"; FAIL=$((FAIL + 1))
  fi
  if echo "$CONT_CMT_OUT" | jq -e '.commands_completed | map(contains("standalone comment")) | any | not' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 16b: comment text never entered a command"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 16b: comment glued into a command: $CONT_CMT_OUT"; FAIL=$((FAIL + 1))
  fi
fi

# 16c: a line ending in an EVEN run of backslashes is a literal backslash, not a
# continuation — it is NOT joined with the next line (leaves genuine literal
# backslashes intact, per the pitfall).
CONT_LIT_PROJ="$TMPDIR_TEST/continuation-literal"
mkdir -p "$CONT_LIT_PROJ"
cat > "$CONT_LIT_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo end\\
echo separate
```
STRIDE
CONT_LIT_OUT=$(echo "$CONT_COMPLETE_JSON" | CLAUDE_PROJECT_DIR="$CONT_LIT_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
if command -v jq > /dev/null 2>&1; then
  if echo "$CONT_LIT_OUT" | jq -e '.commands_completed | length == 2' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 16c: even trailing backslashes do not continue (2 commands)"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 16c: literal backslash wrongly joined: $CONT_LIT_OUT"; FAIL=$((FAIL + 1))
  fi
fi

# ============================================================
# Test Group 17: claim-time dirty baseline guard (W1516)
# ============================================================
echo ""
echo "=== Test Group 17: claim-time dirty baseline guard (W1516) ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: Group 17 requires jq and git"
else
  # End-to-end: claim in a repo that ALREADY has uncommitted/untracked edits,
  # then let the "task" modify one pre-existing file further and add a new one.
  # The after_doing snapshot must exclude the pre-existing, task-untouched edits
  # but keep the pre-existing file the task modified and the new task file.
  BL_DIR="$TMPDIR_TEST/baseline-guard"
  mkdir -p "$BL_DIR"
  (
    cd "$BL_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
GITIGNORE
    echo "committed" > pre_mod.txt
    echo "committed" > untouched_committed.txt
    git add .gitignore pre_mod.txt untouched_committed.txt > /dev/null
    git commit -q -m "init"

    cat > .stride.md << 'STRIDE'
## before_doing
```bash
echo "before_doing_ran"
```
## after_doing
```bash
echo "after_doing_ran"
```
STRIDE

    # PRE-EXISTING dirty state (before the claim): modify a committed file and
    # add an untracked file — both UNRELATED to the task about to be claimed.
    echo "pre-existing unrelated edit" > pre_mod.txt
    echo "pre-existing untracked junk" > pre_new.txt

    # Claim (before_doing) with a parseable task response so the env cache —
    # including TASK_BASE_REF and the new TASK_DIRTY_BASELINE — is written.
    CLAIM_JSON_BL='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":777,\"identifier\":\"W777\",\"title\":\"Baseline Task\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}"}'
    echo "$CLAIM_JSON_BL" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1

    # The TASK does its work: modify the pre-existing file FURTHER, add a new
    # file; leave pre_new.txt untouched.
    echo "TASK further modification" > pre_mod.txt
    echo "task output" > task_new.txt

    # Complete (after_doing) writes .stride-changed-files.json.
    COMPLETE_JSON_BL='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/777/complete"}}'
    echo "$COMPLETE_JSON_BL" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  BL_ENV=$(cat "$BL_DIR/.stride-env-cache" 2>/dev/null)
  BL_SNAP=$(cat "$BL_DIR/.stride-changed-files.json" 2>/dev/null)

  # 17a: the env cache records a TASK_DIRTY_BASELINE alongside TASK_BASE_REF.
  assert_contains "17a: env cache records TASK_DIRTY_BASELINE" "TASK_DIRTY_BASELINE=" "$BL_ENV"
  assert_contains "17a: env cache still records TASK_BASE_REF" "TASK_BASE_REF=" "$BL_ENV"

  # 17b: a pre-existing, task-untouched edit is excluded from the snapshot.
  if echo "$BL_SNAP" | jq -e 'map(.path) | index("pre_new.txt") == null' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 17b: pre-existing untouched untracked file excluded"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 17b: pre-existing untouched file leaked into snapshot: $BL_SNAP"; FAIL=$((FAIL + 1))
  fi

  # 17c: a pre-existing file the task modified FURTHER is still captured.
  if echo "$BL_SNAP" | jq -e 'map(.path) | index("pre_mod.txt") != null' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 17c: pre-existing file modified by the task is still captured"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 17c: task-modified pre-existing file wrongly filtered: $BL_SNAP"; FAIL=$((FAIL + 1))
  fi

  # 17d: a brand-new task file is captured.
  if echo "$BL_SNAP" | jq -e 'map(.path) | index("task_new.txt") != null' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 17d: new task file captured"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 17d: new task file missing from snapshot: $BL_SNAP"; FAIL=$((FAIL + 1))
  fi

  # 17e: self-artifact exclusion (D67) still holds — the snapshot never lists
  # its own bookkeeping files.
  if echo "$BL_SNAP" | jq -e 'map(.path) | (index(".stride-changed-files.json") == null) and (index(".stride-diff-upload-state") == null)' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: 17e: self-artifact exclusion preserved"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: 17e: self-artifact leaked: $BL_SNAP"; FAIL=$((FAIL + 1))
  fi
fi

# ============================================================
# Test Group 18: D119 hook-initiated after_goal detection
# ============================================================
# The reliability guarantee: when the agent-handed /complete response is
# truncated/absent, the hook detects after_goal via its OWN fresh
# GET /api/tasks/:id/after_goal_status call (immune to Bash-tool truncation) and
# runs ## after_goal from the endpoint's compact GOAL_* env. The D118 fast path
# short-circuits the fresh call when a full response is already available, and
# the two paths never both run the section (de-dup).
echo ""
echo "=== Test Group 18: D119 hook-initiated after_goal detection ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 18 requires jq"
else
  # Build a project whose ## after_goal echoes the exported GOAL_IDENTIFIER.
  d119_project() {
    local _dir="$TMPDIR_TEST/d119-$1"
    mkdir -p "$_dir"
    cat > "$_dir/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "after_goal ran for $GOAL_IDENTIFIER"
```
STRIDE
    printf "TASK_ID='42'\n" > "$_dir/.stride-env-cache"
    printf '%s' "$_dir"
  }

  # A curl stub that answers the after_goal_status GET with a JSON body and logs
  # the hit. $2=armed(true|false), $3=call-log path, $4=exit code (0 ok).
  d119_curl_stub() {
    local _stub="$1" _armed="$2" _log="$3" _exit="${4:-0}"
    mkdir -p "$_stub"
    cat > "$_stub/curl" << CURLSTUB
#!/usr/bin/env bash
_hit=""
for a in "\$@"; do
  case "\$a" in */after_goal_status) _hit=1 ;; esac
done
if [ -n "\$_hit" ]; then
  echo hit >> "$_log"
  [ "$_exit" -ne 0 ] && exit $_exit
  if [ "$_armed" = "true" ]; then
    printf '%s' '{"after_goal_armed":true,"goal_id":55,"goal_identifier":"G7","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G7","GOAL_TITLE":"Goal Seven","HOOK_NAME":"after_goal"}}'
  else
    printf '%s' '{"after_goal_armed":false,"goal_id":null,"goal_identifier":null,"env":{}}'
  fi
fi
exit 0
CURLSTUB
    chmod +x "$_stub/curl"
  }

  # A /complete input with a truncated stdout (invalid JSON) and a URL+Bearer in
  # the command so resolve_stride_api_url/token succeed with no .stride_auth.md.
  D119_TRUNC_INPUT='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/42/complete -H \"Authorization: Bearer tok\""},"tool_response":{"stdout":"{\"data\":{\"id\":42},\"hoo"}}'

  # 18a: truncated response + NO response file + armed endpoint → the fresh call
  # detects and runs ## after_goal (the exact condition that broke inline parsing).
  D18A_PROJ=$(d119_project "armed")
  D18A_STUB=$(mktemp -d)
  D18A_LOG="$D18A_PROJ/curl.log"
  d119_curl_stub "$D18A_STUB" "true" "$D18A_LOG"
  D18A_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D18A_PROJ" PATH="$D18A_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  D18A_RC=$?
  assert_exit "18a: hook-initiated after_goal exits 0" 0 "$D18A_RC"
  assert_contains "18a: fresh call ran ## after_goal with the endpoint's GOAL_IDENTIFIER" "after_goal ran for G7" "$D18A_OUT"
  assert_contains "18a: the after_goal_status endpoint was called" "hit" "$(cat "$D18A_LOG" 2>/dev/null)"
  rm -rf "$D18A_STUB"

  # 18b: armed=false → ## after_goal does NOT run (endpoint answered definitively).
  D18B_PROJ=$(d119_project "notarmed")
  D18B_STUB=$(mktemp -d)
  D18B_LOG="$D18B_PROJ/curl.log"
  d119_curl_stub "$D18B_STUB" "false" "$D18B_LOG"
  D18B_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D18B_PROJ" PATH="$D18B_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  if echo "$D18B_OUT" | grep -qF "after_goal ran"; then
    echo -e "  ${RED}FAIL${RESET}: 18b: ## after_goal ran despite armed=false"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 18b: armed=false does not run ## after_goal"
    PASS=$((PASS + 1))
  fi
  assert_contains "18b: the endpoint was still consulted" "hit" "$(cat "$D18B_LOG" 2>/dev/null)"
  rm -rf "$D18B_STUB"

  # 18c (de-dup): a present canonical response file (fast path) runs the section
  # ONCE from the file and the fresh after_goal_status endpoint is NOT called.
  D18C_PROJ=$(d119_project "dedup")
  mkdir -p "$D18C_PROJ/.stride"
  printf '%s' '{"data":{"id":42},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G9"}}]}' \
    > "$D18C_PROJ/.stride/.last-api-response.json"
  D18C_STUB=$(mktemp -d)
  D18C_LOG="$D18C_PROJ/curl.log"
  d119_curl_stub "$D18C_STUB" "true" "$D18C_LOG"
  D18C_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D18C_PROJ" PATH="$D18C_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "18c: fast path runs ## after_goal from the canonical file (G9)" "after_goal ran for G9" "$D18C_OUT"
  # Count only the EXPANDED output line ("ran for G9") — the raw command line
  # carries the literal "$GOAL_IDENTIFIER", so counting the expansion isolates
  # real section runs from the echoed command text.
  D18C_RUNS=$(printf '%s\n' "$D18C_OUT" | grep -cF "ran for G9")
  assert_eq "18c: ## after_goal ran exactly once (de-dup)" "1" "$D18C_RUNS"
  if [ -f "$D18C_LOG" ]; then
    echo -e "  ${RED}FAIL${RESET}: 18c: fast path did not short-circuit — endpoint was called"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 18c: fast path short-circuits the fresh call (endpoint not hit)"
    PASS=$((PASS + 1))
  fi
  rm -rf "$D18C_STUB"

  # 18d: endpoint unreachable (curl fails) → clean no-op, exit 0, section not run
  # (the grace-window worker still completes the goal).
  D18D_PROJ=$(d119_project "unreachable")
  D18D_STUB=$(mktemp -d)
  D18D_LOG="$D18D_PROJ/curl.log"
  d119_curl_stub "$D18D_STUB" "true" "$D18D_LOG" 7
  D18D_OUT=$(echo "$D119_TRUNC_INPUT" | CLAUDE_PROJECT_DIR="$D18D_PROJ" PATH="$D18D_STUB:$PATH" bash "$HOOK_SCRIPT" post 2>&1)
  D18D_RC=$?
  assert_exit "18d: unreachable endpoint still exits 0" 0 "$D18D_RC"
  if echo "$D18D_OUT" | grep -qF "after_goal ran"; then
    echo -e "  ${RED}FAIL${RESET}: 18d: ran ## after_goal despite an unreachable endpoint"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 18d: unreachable endpoint degrades to a clean no-op"
    PASS=$((PASS + 1))
  fi
  rm -rf "$D18D_STUB"
fi

# ============================================================
# Test Group 19: after_goal reliability under truncation (W1612)
# ============================================================
# End-to-end lock-in of the D118/W1609/D119 fix: under the exact oversized-
# response condition that broke after_goal (the harness truncates
# tool_response.stdout), prove the section is detected, GOAL_* is exported, and
# ## after_goal runs via the canonical response file — plus the parent_id
# fallback and missing-section edge cases, and a no-file no-false-positive
# control, all under truncation. (The truncated-stdout + no-file fresh-call path
# itself is covered by Group 18; Group 8 (8q) covers env-cache-free forwarding.)
echo ""
echo "=== Test Group 19: after_goal reliability under truncation (W1612) ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq missing — Group 19 requires jq"
else
  # A /complete input whose stdout is truncated mid-JSON (invalid), so detection
  # MUST come from the canonical response file, not the handed stdout.
  W1612_TRUNC='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"},"tool_response":{"stdout":"{\"data\":{\"id\":99},\"hoo"}}'

  # 19a: truncated stdout + present canonical file with a full after_goal entry
  # -> the section runs, GOAL_* reaches the section AND the env cache (the
  # end-to-end reliability proof for the agent's follow-up PATCH).
  W19A_PROJ="$TMPDIR_TEST/w1612-fastpath"
  mkdir -p "$W19A_PROJ/.stride"
  cat > "$W19A_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER] title=[$GOAL_TITLE]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"parent_id":55},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55","GOAL_TITLE":"Goal 55"}}]}' \
    > "$W19A_PROJ/.stride/.last-api-response.json"
  W19A_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W19A_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W19A_RC=$?
  assert_exit "19a: truncated /complete with a present file exits 0" 0 "$W19A_RC"
  assert_contains "19a: ## after_goal ran with GOAL_IDENTIFIER from the file" "ident=[G55]" "$W19A_OUT"
  assert_contains "19a: GOAL_TITLE exported to the section" "title=[Goal 55]" "$W19A_OUT"
  W19A_CACHE=$(cat "$W19A_PROJ/.stride-env-cache" 2>/dev/null)
  assert_contains "19a: env cache carries GOAL_ID for the follow-up PATCH" "GOAL_ID='55'" "$W19A_CACHE"

  # 19b: truncated stdout + present file whose after_goal env OMITS GOAL_ID but
  # data.parent_id is set -> the parent-id fallback exports GOAL_ID under truncation.
  W19B_PROJ="$TMPDIR_TEST/w1612-parentid"
  mkdir -p "$W19B_PROJ/.stride"
  cat > "$W19B_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
STRIDE
  printf '%s' '{"data":{"id":99,"parent_id":77},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G77"}}]}' \
    > "$W19B_PROJ/.stride/.last-api-response.json"
  W19B_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W19B_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  assert_contains "19b: GOAL_ID falls back to data.parent_id under truncation" "goal=[77]" "$W19B_OUT"
  assert_contains "19b: GOAL_IDENTIFIER still exported from the file" "ident=[G77]" "$W19B_OUT"

  # 19c: truncated stdout + present file WITH an after_goal entry, but the
  # ## after_goal section is MISSING from .stride.md -> clean no-op (exit 0, no
  # structured after_goal JSON emitted).
  W19C_PROJ="$TMPDIR_TEST/w1612-missing"
  mkdir -p "$W19C_PROJ/.stride"
  cat > "$W19C_PROJ/.stride.md" << 'STRIDE'
## before_review
```bash
echo "before_review_ran"
```
STRIDE
  printf '%s' '{"data":{"id":99},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G88"}}]}' \
    > "$W19C_PROJ/.stride/.last-api-response.json"
  W19C_OUT=$(echo "$W1612_TRUNC" | CLAUDE_PROJECT_DIR="$W19C_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W19C_RC=$?
  assert_exit "19c: missing ## after_goal under truncation exits 0" 0 "$W19C_RC"
  if echo "$W19C_OUT" | grep -qF '"hook": "after_goal"'; then
    echo -e "  ${RED}FAIL${RESET}: 19c: emitted after_goal JSON despite a missing section"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 19c: missing ## after_goal is a clean no-op under truncation"
    PASS=$((PASS + 1))
  fi

  # 19d: no-file control — truncated stdout, NO canonical file, and no reachable
  # after_goal_status endpoint -> the section must NOT run (no false positive).
  W19D_PROJ="$TMPDIR_TEST/w1612-nofile"
  mkdir -p "$W19D_PROJ"
  cat > "$W19D_PROJ/.stride.md" << 'STRIDE'
## after_goal
```bash
echo "after_goal_ran"
```
STRIDE
  printf "TASK_ID='99'\n" > "$W19D_PROJ/.stride-env-cache"
  W19D_INPUT='{"tool_input":{"command":"curl -X PATCH http://localhost:19099/api/tasks/99/complete -H \"Authorization: Bearer tok\""},"tool_response":{"stdout":"{\"data\":{\"id\":99},\"hoo"}}'
  W19D_OUT=$(echo "$W19D_INPUT" | CLAUDE_PROJECT_DIR="$W19D_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  W19D_RC=$?
  assert_exit "19d: no-file + truncated + unreachable exits 0" 0 "$W19D_RC"
  if echo "$W19D_OUT" | grep -qF "after_goal_ran"; then
    echo -e "  ${RED}FAIL${RESET}: 19d: false-positive after_goal run with no file and no endpoint"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 19d: no file + no endpoint does not run ## after_goal (no false positive)"
    PASS=$((PASS + 1))
  fi
fi

# ============================================================
# Test Group 20: D142 — post-pull TASK_BASE_REF + complete snapshot
# (ports the reference plugin's Test Group 21 to copilot's base64
# TASK_DIRTY_BASELINE transport)
# ============================================================
# Two production defects, both silent review corruption:
#   D132: TASK_BASE_REF was captured BEFORE the ## before_doing section ran,
#         so the section's `git pull` moved HEAD past it and the after_doing
#         diff spanned another clone's already-completed task.
#   D137: the claim-time dirty-baseline filter (W1516) excluded files whose
#         content had not changed since claim — even after the after_doing
#         auto-commit committed them as the task's own work — silently
#         dropping tracked edits and an untracked migration.
echo ""
echo "=== Test Group 20: D142 post-pull TASK_BASE_REF + complete snapshot ==="

if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: jq or git missing — Group 20 requires both (reuses Group 9 helpers)"
else
  # Shared fixture: a bare origin and two clones. Clone A is the task machine;
  # clone B plays the OTHER computer whose completed task arrives via the
  # ## before_doing pull on clone A.
  D142_ROOT=$(mktemp -d)
  git init -q --bare "$D142_ROOT/origin.git"
  # Point the bare HEAD at main so both clones check out the same branch
  # regardless of the host's init.defaultBranch.
  git -C "$D142_ROOT/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$D142_ROOT/origin.git" "$D142_ROOT/cloneA" 2> /dev/null
  (
    cd "$D142_ROOT/cloneA" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
    git checkout -q -b main 2> /dev/null || git checkout -q main
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
*.ref
GITIGNORE
    echo "base" > base.txt
    git add .gitignore base.txt > /dev/null
    git commit -q -m "base"
    git push -q origin main 2> /dev/null
  )
  git clone -q "$D142_ROOT/origin.git" "$D142_ROOT/cloneB" 2> /dev/null
  (
    cd "$D142_ROOT/cloneB" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
    echo "w1678" > w1678.txt
    git add w1678.txt > /dev/null
    git commit -q -m "other clone's task"
    git push -q origin main 2> /dev/null
  )

  # 20a: the claim-time refresh must record the POST-pull branch point, even
  # when the cache already holds a stale base from a previous task/session.
  (
    cd "$D142_ROOT/cloneA" || exit 1
    cat > .stride.md << 'STRIDE'
## before_doing
```bash
git pull -q origin main
```

## after_doing
```bash
git add -A
git commit -q -m "task commit"
```
STRIDE
    # Stale cache from a "previous session" — must be fully replaced.
    printf "TASK_ID='OLD1'\nTASK_BASE_REF='1111111111111111111111111111111111111111'\n" > .stride-env-cache
    git rev-parse HEAD > prepull.ref
    D142_CLAIM='{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":142,\"identifier\":\"D142\",\"title\":\"Cross clone\",\"status\":\"in_progress\",\"complexity\":\"medium\",\"priority\":\"high\"}}","stderr":"","interrupted":false}}'
    echo "$D142_CLAIM" | CLAUDE_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  D142_PREPULL=$(cat "$D142_ROOT/cloneA/prepull.ref")
  D142_HEAD=$(git -C "$D142_ROOT/cloneA" rev-parse HEAD)
  D142_CACHE=$(cat "$D142_ROOT/cloneA/.stride-env-cache" 2>/dev/null)
  if [ "$D142_PREPULL" = "$D142_HEAD" ]; then
    echo -e "  ${RED}FAIL${RESET}: 20a fixture vacuous — the before_doing pull did not move HEAD"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 20a fixture: the before_doing pull moved HEAD (discriminating power)"
    PASS=$((PASS + 1))
  fi
  assert_contains "20a: claim records the POST-pull branch point as TASK_BASE_REF" \
    "TASK_BASE_REF='$D142_HEAD'" "$D142_CACHE"
  if echo "$D142_CACHE" | grep -q "1111111111111111111111111111111111111111"; then
    echo -e "  ${RED}FAIL${RESET}: 20a: the stale prior-session TASK_BASE_REF survived the claim"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 20a: the stale prior-session TASK_BASE_REF was replaced"
    PASS=$((PASS + 1))
  fi

  # 20b: completing the task on clone A captures ONLY the task's own files —
  # never the commit pulled from clone B (the D132/W1678 cross-task scenario).
  D142_STUB=$(mktemp -d)
  D142_FIXTURE="$D142_ROOT/cloneA/curl-call.txt"
  make_curl_stub "$D142_STUB" "$D142_FIXTURE" 0 200
  (
    cd "$D142_ROOT/cloneA" || exit 1
    echo "task work" > task.txt
    D142_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/142/complete -H \"Authorization: Bearer tok\""}}'
    echo "$D142_COMPLETE" | CLAUDE_PROJECT_DIR="$PWD" PATH="$D142_STUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  D142_PATHS=$(jq -r '.[].path' "$D142_ROOT/cloneA/.stride-changed-files.json" 2>/dev/null)
  assert_contains "20b: snapshot contains the task's own file" "task.txt" "$D142_PATHS"
  if echo "$D142_PATHS" | grep -qx "w1678.txt"; then
    echo -e "  ${RED}FAIL${RESET}: 20b: the other clone's pulled file leaked into the snapshot"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 20b: the other clone's pulled file is NOT in the snapshot"
    PASS=$((PASS + 1))
  fi

  # 20c: resolve_snapshot_base — the staleness guard. cloneA's history is now
  # base → w1678 (pulled) → task commit, with origin/main at w1678: the task
  # branch point (merge-base of HEAD and origin/main) is the w1678 commit.
  D142_BP=$(git -C "$D142_ROOT/cloneA" merge-base HEAD origin/main)
  D142_ERR_FILE=$(mktemp)
  D142_RES=$(
    cd "$D142_ROOT/cloneA" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "$D142_PREPULL" 2> "$D142_ERR_FILE"
  )
  assert_eq "20c: a base older than the branch point recomputes to the branch point" \
    "$D142_BP" "$D142_RES"
  assert_contains "20c: the recompute says so in its output" \
    "recomputed" "$(cat "$D142_ERR_FILE" 2>/dev/null)"
  D142_RES_OK=$(
    cd "$D142_ROOT/cloneA" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "$D142_BP" 2> "$D142_ERR_FILE.trusted"
  )
  assert_eq "20c: a base equal to the branch point is trusted unchanged" \
    "$D142_BP" "$D142_RES_OK"
  assert_eq "20c: a trusted base emits no recompute notice" \
    "" "$(cat "$D142_ERR_FILE.trusted" 2>/dev/null)"
  D142_RES_BAD=$(
    cd "$D142_ROOT/cloneA" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null
  )
  assert_eq "20c: an unresolvable base recomputes to the branch point" \
    "$D142_BP" "$D142_RES_BAD"
  rm -f "$D142_ERR_FILE" "$D142_ERR_FILE.trusted"

  # 20c2: a repo with NO origin has no branch point to recompute from — the
  # guard must pass the base through unchanged (no cross-clone pull is possible
  # without a remote, so the D132 scenario cannot occur there).
  D142_LOCAL=$(mktemp -d)
  (
    cd "$D142_LOCAL" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
    echo "x" > x.txt
    git add x.txt > /dev/null
    git commit -q -m x
  )
  D142_RES_LOCAL=$(
    cd "$D142_LOCAL" || exit 99
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    resolve_snapshot_base "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>/dev/null
  )
  assert_eq "20c2: no origin — the base passes through unchanged" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$D142_RES_LOCAL"
  rm -rf "$D142_LOCAL"
  rm -rf "$D142_ROOT" "$D142_STUB"

  # 20d: D137 dropped-files repro — files already dirty/untracked at claim time
  # that the after_doing auto-commit then COMMITS are the task's own work and
  # must survive the dirty-baseline filter. copilot's baseline rides in the
  # env-cache base64 TASK_DIRTY_BASELINE line, so it is computed over the dirty
  # tree BEFORE the auto-commit, exactly as finalize_before_doing does.
  D137_DIR=$(mktemp -d)
  (
    cd "$D137_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
    cat > .gitignore << 'GITIGNORE'
base.ref
snap.json
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
GITIGNORE
    printf 'v1\n' > lib_a.txt
    printf 'v1\n' > lib_b.txt
    git add . > /dev/null
    git commit -q -m "base"
    git rev-parse HEAD > base.ref
    # The D137 shape: task work already present when the claim lands.
    printf 'v2\n' > lib_a.txt
    printf 'v2\n' > lib_b.txt
    printf 'defmodule Migration do end\n' > migration.exs
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    HAS_JQ=true
    # copilot: the dirty baseline is the base64 env var computed over the
    # CURRENT (pre-commit) dirty tree — the claim-time hashes.
    export TASK_DIRTY_BASELINE=$(_compute_dirty_baseline | base64 2>/dev/null | tr -d '\r\n')
    # The after_doing auto-commit commits ALL of it as the task's work.
    git add -A > /dev/null
    git commit -q -m "task"
    capture_changed_files "$(cat base.ref)" > snap.json 2>/dev/null
  )
  D137_PATHS=$(jq -r '.[].path' "$D137_DIR/snap.json" 2>/dev/null)
  assert_contains "20d: committed tracked edit survives the baseline filter (a)" "lib_a.txt" "$D137_PATHS"
  assert_contains "20d: committed tracked edit survives the baseline filter (b)" "lib_b.txt" "$D137_PATHS"
  assert_contains "20d: committed formerly-untracked migration is included" "migration.exs" "$D137_PATHS"

  # 20e: snapshot/commit parity — the uploaded file list equals the task
  # commit's file list exactly in the normal flow.
  D137_COMMIT_FILES=$(git -C "$D137_DIR" diff --name-only "$(cat "$D137_DIR/base.ref")" HEAD | sort)
  D137_SNAP_FILES=$(printf '%s\n' "$D137_PATHS" | sort)
  assert_eq "20e: snapshot file list equals the commit file list" \
    "$D137_COMMIT_FILES" "$D137_SNAP_FILES"
  rm -rf "$D137_DIR"

  # 20f: finalize_before_doing works WITHOUT jq — a stale inherited base is
  # rewritten to HEAD and identity lines survive (the old claim refresh was
  # entirely jq-gated, so a no-jq environment kept the stale base forever).
  D142_NOJQ=$(mktemp -d)
  (
    cd "$D142_NOJQ" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
    echo "v1" > a.txt
    git add a.txt > /dev/null
    git commit -q -m "v1"
    printf "TASK_ID='7'\nTASK_BASE_REF='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'\n" > .stride-env-cache
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null
    PROJECT_DIR="$PWD"
    ENV_CACHE="$PWD/.stride-env-cache"
    HAS_JQ=false
    HOOK_NAME=before_doing
    finalize_before_doing
  )
  D142_NOJQ_HEAD=$(git -C "$D142_NOJQ" rev-parse HEAD)
  D142_NOJQ_CACHE=$(cat "$D142_NOJQ/.stride-env-cache" 2>/dev/null)
  assert_contains "20f: no-jq finalize rewrites the stale base to HEAD" \
    "TASK_BASE_REF='$D142_NOJQ_HEAD'" "$D142_NOJQ_CACHE"
  assert_contains "20f: finalize stamps the trust marker" "TASK_BASE_REF_TRUSTED='1'" "$D142_NOJQ_CACHE"
  assert_contains "20f: identity lines survive the rewrite" "TASK_ID='7'" "$D142_NOJQ_CACHE"
  if echo "$D142_NOJQ_CACHE" | grep -q "deadbeef"; then
    echo -e "  ${RED}FAIL${RESET}: 20f: the stale base survived the no-jq rewrite"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 20f: the stale base did not survive the no-jq rewrite"
    PASS=$((PASS + 1))
  fi
  rm -rf "$D142_NOJQ"

  # 20g: an ## after_doing section that PUSHES the default branch must not trick
  # the refresh capture into recomputing the (correct) base — the push moves
  # origin/main to HEAD before the post-command refresh, which would make the
  # base a strict ancestor of the new branch point and empty the snapshot. The
  # guard's judgment is resolved once at the pre-command early capture and
  # memoized, and the resolved base is persisted for the self-heal.
  D142_PUSH=$(mktemp -d)
  git init -q --bare "$D142_PUSH/origin.git"
  git -C "$D142_PUSH/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$D142_PUSH/origin.git" "$D142_PUSH/work" 2> /dev/null
  D142_PUSH_STUB=$(mktemp -d)
  D142_PUSH_FIXTURE="$D142_PUSH/work/curl-call.txt"
  make_curl_stub "$D142_PUSH_STUB" "$D142_PUSH_FIXTURE" 0 200
  (
    cd "$D142_PUSH/work" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
    git checkout -q -b main 2> /dev/null || git checkout -q main
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
*.ref
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
    git push -q origin main 2> /dev/null
    git rev-parse HEAD > base.ref
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "task work"
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
git push -q origin main
```
STRIDE
    printf "TASK_ID='55'\nTASK_BASE_REF='%s'\n" "$(cat base.ref)" > .stride-env-cache
    D142_PUSH_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/55/complete -H \"Authorization: Bearer tok\""}}'
    echo "$D142_PUSH_COMPLETE" | CLAUDE_PROJECT_DIR="$PWD" PATH="$D142_PUSH_STUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  D142_PUSH_BASE=$(cat "$D142_PUSH/work/base.ref")
  D142_PUSH_PATHS=$(jq -r '.[].path' "$D142_PUSH/work/.stride-changed-files.json" 2>/dev/null)
  assert_contains "20g: push-in-after_doing keeps the task's file in the snapshot" \
    "tracked.txt" "$D142_PUSH_PATHS"
  assert_contains "20g: the resolved base is persisted for the self-heal" \
    "base=$D142_PUSH_BASE" "$(cat "$D142_PUSH/work/.stride-diff-upload-state" 2>/dev/null)"
  rm -rf "$D142_PUSH" "$D142_PUSH_STUB"

  # 20h: a workflow that pushes its own task commits BEFORE completing
  # (origin/main == HEAD at capture time) must not have its correct,
  # claim-written base recomputed — the TASK_BASE_REF_TRUSTED marker written by
  # finalize_before_doing exempts the base from the branch-point rule.
  D142_PRE=$(mktemp -d)
  git init -q --bare "$D142_PRE/origin.git"
  git -C "$D142_PRE/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$D142_PRE/origin.git" "$D142_PRE/work" 2> /dev/null
  D142_PRE_STUB=$(mktemp -d)
  D142_PRE_FIXTURE="$D142_PRE/work/curl-call.txt"
  make_curl_stub "$D142_PRE_STUB" "$D142_PRE_FIXTURE" 0 200
  (
    cd "$D142_PRE/work" || exit 1
    git config user.email "test@test.local"
    git config user.name "Test"
    git config commit.gpgsign false
    git checkout -q -b main 2> /dev/null || git checkout -q main
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
.stride-diff-upload-state
curl-call.txt
*.ref
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1"
    git push -q origin main 2> /dev/null
    git rev-parse HEAD > base.ref
    # Task commits made AND pushed before /complete runs.
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "task work"
    git push -q origin main 2> /dev/null
    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "gate ran"
```
STRIDE
    printf "TASK_ID='56'\nTASK_BASE_REF='%s'\nTASK_BASE_REF_TRUSTED='1'\n" "$(cat base.ref)" > .stride-env-cache
    D142_PRE_COMPLETE='{"tool_input":{"command":"curl -X PATCH https://stride.example.com/api/tasks/56/complete -H \"Authorization: Bearer tok\""}}'
    echo "$D142_PRE_COMPLETE" | CLAUDE_PROJECT_DIR="$PWD" PATH="$D142_PRE_STUB:$PATH" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  D142_PRE_PATHS=$(jq -r '.[].path' "$D142_PRE/work/.stride-changed-files.json" 2>/dev/null)
  assert_contains "20h: pre-pushed task work stays in the snapshot (trusted base not re-judged)" \
    "tracked.txt" "$D142_PRE_PATHS"
  rm -rf "$D142_PRE" "$D142_PRE_STUB"
fi

# ============================================================
# Test Group 21: W2147 loop state recorded on completion
# ============================================================
# The Stop gate cannot refuse an action it has no evidence for. These cover the
# file that becomes that evidence: written when a completion SUCCEEDS, cleared
# when the next claim proves it was followed, and never written for a failure.
# Mirrors the reference plugin's Test Group 33 case-for-case, plus 21w, which
# asserts the cross-half byte identity AC5 requires.
echo ""
echo "=== Test Group 21: W2147 loop state on completion (bash) ==="

if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: jq not available — Group 21 requires jq"
else
  G21_URL="https://www.stridelikeaboss.com"
  G21_STATE=".stride/.loop-state.json"

  # Build a hook-input envelope. $1=session_id $2=command $3=stdout payload
  g21_input() {
    jq -nc --arg s "$1" --arg c "$2" --arg r "$3" \
      '{session_id:$s,tool_input:{command:$c},tool_response:{stdout:$r}}'
  }

  # Fresh project dir with only the sections under test, so nothing else runs.
  g21_proj() {
    local _d="$TMPDIR_TEST/w2147-$1"
    rm -rf "$_d"; mkdir -p "$_d/.stride"
    printf '## before_doing\n```bash\n```\n\n## before_review\n```bash\n```\n' > "$_d/.stride.md"
    printf '%s' "$_d"
  }

  G21_OK='{"data":{"id":99,"identifier":"W2147","needs_review":false},"hooks":[{"name":"before_review"}]}'
  G21_COMPLETE_CMD="curl -sS -X PATCH $G21_URL/api/tasks/99/complete -d @payload.json | tee r.json"
  G21_CLAIM_CMD="curl -sS -X POST $G21_URL/api/tasks/claim -d @c.json | tee r.json"

  # 21a: a successful completion writes the file with the right identifier.
  G21_D=$(g21_proj a)
  g21_input "sess-abc" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21a: a successful completion records the identifier" \
    "W2147" "$(jq -r '.identifier' "$G21_D/$G21_STATE" 2>/dev/null)"
  assert_eq "21a: it records needs_review from the response" \
    "false" "$(jq -r '.needs_review' "$G21_D/$G21_STATE" 2>/dev/null)"
  assert_eq "21a: it records the session id" \
    "sess-abc" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"
  assert_eq "21a: completed_at is an ISO8601 Z timestamp" "ok" \
    "$(jq -r 'if (.completed_at // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then "ok" else "no" end' "$G21_D/$G21_STATE" 2>/dev/null)"

  # 21b: needs_review=true is recorded VERBATIM, and as a JSON boolean rather
  # than the string "true" — the gate branches on it.
  G21_D=$(g21_proj b)
  g21_input "s" "$G21_COMPLETE_CMD" \
    '{"data":{"id":99,"identifier":"W555","needs_review":true},"hooks":[{"name":"before_review"}]}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21b: needs_review=true is recorded verbatim" \
    "true" "$(jq -r '.needs_review' "$G21_D/$G21_STATE" 2>/dev/null)"
  assert_eq "21b: needs_review is a boolean, not a string" \
    "boolean" "$(jq -r '.needs_review | type' "$G21_D/$G21_STATE" 2>/dev/null)"

  # 21c: the session id falls back to CLAUDE_SESSION_ID when the input omits it.
  G21_D=$(g21_proj c)
  jq -nc --arg c "$G21_COMPLETE_CMD" --arg r "$G21_OK" \
    '{tool_input:{command:$c},tool_response:{stdout:$r}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" CLAUDE_SESSION_ID="env-sess" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21c: the session id falls back to CLAUDE_SESSION_ID" \
    "env-sess" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"

  # 21d: with no session id anywhere it degrades to "unknown" rather than
  # dropping the record — the identifier is the field the gate needs. This is
  # the ORDINARY case on this runtime: Copilot's documented hook payload has no
  # session field, so the attempt-then-degrade chain exists to keep the two
  # halves identical rather than because a session id is expected today.
  G21_D=$(g21_proj d)
  jq -nc --arg c "$G21_COMPLETE_CMD" --arg r "$G21_OK" \
    '{tool_input:{command:$c},tool_response:{stdout:$r}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" CLAUDE_SESSION_ID="" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21d: an absent session id degrades to unknown" \
    "unknown" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"

  # 21e: a session id that is not identifier-shaped is refused, not sanitised.
  G21_D=$(g21_proj e)
  g21_input 'not a/session id' "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21e: a non-identifier-shaped session id degrades to unknown" \
    "unknown" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"

  # 21f: a 422 does NOT write the file. Every non-success body the API emits
  # lacks .data, which is the discriminator — curl has no -f here, so the error
  # body lands on stdout exactly like a success body would.
  G21_D=$(g21_proj f)
  g21_input "s" "$G21_COMPLETE_CMD" '{"errors":{"completion_summary":["can'"'"'t be blank"]}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21f: a 422 completion must not write the loop state"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21f: a 422 completion does not write the loop state"
    PASS=$((PASS + 1))
  fi

  # 21g: THE REGRESSION GUARD for AC4. extract_response_payload is
  # canonical-file-first (D118) and .stride/.last-api-response.json survives
  # across calls, so a build on it as the Tier-1 source would resolve the
  # previous CLAIM payload here — which carries both fields — and record a
  # completion that never happened. A naive implementation passes 21f and
  # fails this.
  G21_D=$(g21_proj g)
  cat > "$G21_D/.stride/.last-api-response.json" << 'G21STALE'
{"data":{"id":99,"identifier":"W9999","needs_review":true},"hook":{"name":"before_doing"}}
G21STALE
  g21_input "s" "$G21_COMPLETE_CMD" '{"errors":{"base":["unprocessable"]}, TRUNCA' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21g: a truncated 422 must not inherit the previous claim's payload"
    echo "    wrote: $(cat "$G21_D/$G21_STATE")"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21g: a truncated 422 does not inherit the previous claim's payload"
    PASS=$((PASS + 1))
  fi

  # 21h: the other side of 21g — a harness-truncated SUCCESS still records, via
  # the canonical snapshot, but only because it demonstrably belongs to THIS
  # completion (hooks is an array, and the task id matches the routed id).
  G21_D=$(g21_proj h)
  cat > "$G21_D/.stride/.last-api-response.json" << 'G21FRESH'
{"data":{"id":99,"identifier":"W777","needs_review":false},"hooks":[{"name":"before_review"}]}
G21FRESH
  g21_input "s" "$G21_COMPLETE_CMD" '{"data":{"identifier":"W7 TRUNCA' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21h: a truncated success recovers from the matching snapshot" \
    "W777" "$(jq -r '.identifier' "$G21_D/$G21_STATE" 2>/dev/null)"

  # 21i: and that recovery refuses a snapshot belonging to a DIFFERENT task.
  G21_D=$(g21_proj i)
  cat > "$G21_D/.stride/.last-api-response.json" << 'G21OTHER'
{"data":{"id":12345,"identifier":"W_OTHER","needs_review":false},"hooks":[{"name":"before_review"}]}
G21OTHER
  g21_input "s" "$G21_COMPLETE_CMD" '{"data": TRUNCA' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21i: recovery must refuse a snapshot for another task id"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21i: recovery refuses a snapshot for another task id"
    PASS=$((PASS + 1))
  fi

  # 21j: a claim clears a stale record. This is the half that makes the gate
  # correct — a leftover from the PREVIOUS task would otherwise fire it on work
  # that is already done.
  G21_D=$(g21_proj j)
  echo '{"identifier":"W_OLD","needs_review":false,"completed_at":"2020-01-01T00:00:00Z","session_id":"old"}' \
    > "$G21_D/$G21_STATE"
  g21_input "s" "$G21_CLAIM_CMD" \
    '{"data":{"id":99,"identifier":"W1"},"hook":{"name":"before_doing"}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21j: a claim must clear the previous completion's loop state"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21j: a claim clears the previous completion's loop state"
    PASS=$((PASS + 1))
  fi

  # 21k: atomicity, from both ends. The writer stages a temp in the destination
  # directory and renames, so a killed hook can leave no partial file — assert
  # no temp survives a success, and assert structurally that the writer never
  # redirects straight at the destination. The `== 1` mktemp assertion doubles
  # as the anti-vacuity guard: an awk range that matched nothing would make the
  # `== 0` assertion above pass for the wrong reason.
  G21_D=$(g21_proj k)
  g21_input "s" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21k: no temp file survives a successful write" \
    "0" "$(find "$G21_D/.stride" -name 'loop-state.*' -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "21k: the writer renames into place rather than redirecting at it" \
    "0" "$(awk '/^write_loop_state\(\)/,/^}/' "$HOOK_SCRIPT" | grep -c '> *"\$LOOP_STATE_FILE"' | tr -d ' ')"
  assert_eq "21k: the writer stages its temp inside the destination directory" \
    "1" "$(awk '/^write_loop_state\(\)/,/^}/' "$HOOK_SCRIPT" | grep -c 'mktemp "\$PROJECT_DIR/.stride/loop-state' | tr -d ' ')"

  # 21l: the file carries exactly the four documented keys and nothing else —
  # never the response body, task free text, or the Bearer token that rides in
  # the same hook input the session id is read from.
  G21_D=$(g21_proj l)
  g21_input "s" \
    "curl -sS -X PATCH $G21_URL/api/tasks/99/complete -H 'Authorization: Bearer stride_dev_SECRETVALUE' -d @p.json | tee r.json" \
    "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21l: the file carries exactly the four documented keys" \
    "completed_at identifier needs_review session_id" \
    "$(jq -r 'keys_unsorted | sort | join(" ")' "$G21_D/$G21_STATE" 2>/dev/null)"
  if grep -q 'SECRETVALUE\|Bearer' "$G21_D/$G21_STATE" 2>/dev/null; then
    echo -e "  ${RED}FAIL${RESET}: 21l: the loop state must never carry the Bearer token"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21l: the loop state never carries the Bearer token"
    PASS=$((PASS + 1))
  fi

  # 21m: an unwritable .stride/ is logged and swallowed. The loop state is a
  # gate input, not a correctness dependency — it must never fail the completion.
  G21_D=$(g21_proj m)
  chmod 500 "$G21_D/.stride" 2>/dev/null
  G21_ERR=$(g21_input "s" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post 2>&1 >/dev/null)
  G21_RC=$?
  chmod 700 "$G21_D/.stride" 2>/dev/null
  assert_exit "21m: an unwritable .stride does not fail the completion" 0 "$G21_RC"
  # The pitfall is "log and continue", so the failure must be announced rather
  # than swallowed silently — on stderr, never stdout, which carries the one
  # JSON document the harness parses.
  assert_contains "21m: an unwritable .stride is announced on stderr" \
    "loop state" "$G21_ERR"

  # 21n: the full claim -> complete -> claim cycle, which is the lifecycle the
  # gate actually observes. Asserted as ONE triple rather than three separate
  # assertions: split up, the middle one could be quietly weakened while the
  # other two still passed.
  G21_D=$(g21_proj n)
  g21_input "s" "$G21_CLAIM_CMD" '{"data":{"id":99,"identifier":"W2147"},"hook":{"name":"before_doing"}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  G21_AFTER_CLAIM=$([ -f "$G21_D/$G21_STATE" ] && echo present || echo absent)
  g21_input "s" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  G21_AFTER_COMPLETE=$([ -f "$G21_D/$G21_STATE" ] && echo present || echo absent)
  g21_input "s" "$G21_CLAIM_CMD" '{"data":{"id":100,"identifier":"W2148"},"hook":{"name":"before_doing"}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  G21_AFTER_NEXT=$([ -f "$G21_D/$G21_STATE" ] && echo present || echo absent)
  assert_eq "21n: claim -> complete -> claim leaves the state absent/present/absent" \
    "absent present absent" "$G21_AFTER_CLAIM $G21_AFTER_COMPLETE $G21_AFTER_NEXT"

  # 21o: the clear is UNCONDITIONAL, including on a FAILED claim, and this case
  # is why. The claim that fails most often is the one against an empty ready
  # queue — how essentially every session ends. Preserving the record there
  # would make it byte-identical to one left by an agent that completed and
  # never claimed at all, and a gate must refuse in the second case but not the
  # first.
  G21_D=$(g21_proj o)
  echo '{"identifier":"W_OLD","needs_review":false,"completed_at":"2020-01-01T00:00:00Z","session_id":"old"}' \
    > "$G21_D/$G21_STATE"
  g21_input "s" "$G21_CLAIM_CMD" '{"errors":{"base":["no task available"]}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21o: an empty-queue claim must still clear (no ambiguous record)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21o: an empty-queue claim still clears (no ambiguous record)"
    PASS=$((PASS + 1))
  fi

  # 21p: and a claim whose payload cannot be PARSED still clears. On this port
  # that is a real risk rather than a formality: the sibling artefact clears sit
  # inside the caching block's `try`, whose ConvertFrom-Json throws on exactly
  # this input, so a loop-state clear placed beside them would be skipped here.
  G21_D=$(g21_proj p)
  echo '{"identifier":"W_OLD","needs_review":false,"completed_at":"2020-01-01T00:00:00Z","session_id":"old"}' \
    > "$G21_D/$G21_STATE"
  g21_input "s" "$G21_CLAIM_CMD" '{"data":{"id":9 TRUNCA' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21p: an unparsable claim must still clear (safe direction)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21p: an unparsable claim still clears (safe direction)"
    PASS=$((PASS + 1))
  fi

  # 21q: a completion carrying NO tool_response at all. Parity with the ps1
  # half, where Set-StrictMode makes an absent property a terminating error;
  # the bash half must be equally unbothered.
  G21_D=$(g21_proj q)
  G21_RC=0
  jq -nc --arg c "$G21_COMPLETE_CMD" '{session_id:"s",tool_input:{command:$c}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1 || G21_RC=$?
  assert_exit "21q: an absent tool_response does not fail the hook" 0 "$G21_RC"
  # The diagnostic channel must stay QUIET here: there was no body at all, so
  # announcing a parse failure would claim something that never happened, and a
  # channel that cries wolf is one an operator learns to ignore.
  G21_ERR=$(jq -nc --arg c "$G21_COMPLETE_CMD" '{session_id:"s",tool_input:{command:$c}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post 2>&1 >/dev/null)
  if echo "$G21_ERR" | grep -q 'unparsable'; then
    echo -e "  ${RED}FAIL${RESET}: 21q: an absent body must not be announced as unparsable"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21q: an absent body is not announced as unparsable"
    PASS=$((PASS + 1))
  fi
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21q: an absent tool_response must write no loop state"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21q: an absent tool_response writes no loop state"
    PASS=$((PASS + 1))
  fi

  # 21r: the charset gate must agree with the PowerShell twin, and the one
  # input where the two shells can silently disagree is a TRAILING newline:
  # bash reads both values through `$( )`, which strips them, so the ps1 half
  # normalises before validating rather than refusing. An INTERIOR newline is
  # refused by both.
  #
  # $'...' (ANSI-C quoting), NOT "$(printf 'abc\n')": command substitution
  # strips the trailing newline before it reaches the fixture, so the latter
  # spelling would assert the stripping behaviour against an input that never
  # contained a newline — the same `$( )` stripping this contract is about,
  # turned back on the test.
  G21_D=$(g21_proj r)
  G21_NL=$'abc\n'
  g21_input "$G21_NL" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21r: a trailing newline in the session id is stripped, not refused" \
    "abc" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"
  # CRLF must ALSO agree: bash's `$( )` strips the LF and leaves the CR, which
  # the charset gate then refuses, so the ps1 half strips LF only for the same
  # result.
  G21_D=$(g21_proj r3)
  G21_CRLF=$'abc\r\n'
  g21_input "$G21_CRLF" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21r: a trailing CRLF in the session id is refused" \
    "unknown" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"
  G21_D=$(g21_proj r2)
  g21_input "$(printf 'a\nb')" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21r: an interior newline in the session id is refused" \
    "unknown" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"

  # 21s: testing_strategy names concurrent sessions in one checkout as an edge
  # case. The design answer is that each writer stages a uniquely named temp
  # and renames, so the loser of the race is overwritten rather than
  # interleaved — assert the observable consequence: exactly one well-formed
  # file, one of the two identifiers, and no temp left behind by either.
  G21_D=$(g21_proj s)
  g21_input "s" "$G21_COMPLETE_CMD" \
    '{"data":{"id":99,"identifier":"W_AAA","needs_review":false},"hooks":[{"name":"before_review"}]}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1 &
  g21_input "s" "$G21_COMPLETE_CMD" \
    '{"data":{"id":99,"identifier":"W_BBB","needs_review":false},"hooks":[{"name":"before_review"}]}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1 &
  wait
  G21_CONC=$(jq -r '.identifier' "$G21_D/$G21_STATE" 2>/dev/null)
  case "$G21_CONC" in
    W_AAA|W_BBB)
      echo -e "  ${GREEN}PASS${RESET}: 21s: concurrent completions leave one well-formed record"
      PASS=$((PASS + 1)) ;;
    *)
      echo -e "  ${RED}FAIL${RESET}: 21s: concurrent completions must leave one well-formed record"
      echo "    actual: $G21_CONC"
      FAIL=$((FAIL + 1)) ;;
  esac
  assert_eq "21s: neither concurrent writer leaves a temp behind" \
    "0" "$(find "$G21_D/.stride" -name 'loop-state.*' -type f 2>/dev/null | wc -l | tr -d ' ')"

  # 21t: a clear that FAILS must be announced. The write path reports all three
  # of its failure modes, so an operator would otherwise be told when a record
  # could not be WRITTEN but never when one could not be CLEARED — the
  # direction the design itself calls dangerous, because the leftover record is
  # exactly what makes a gate fire on work that is already done.
  G21_D=$(g21_proj t)
  g21_input "s" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  chmod 555 "$G21_D/.stride" 2>/dev/null
  G21_ERR=$(g21_input "s" "$G21_CLAIM_CMD" \
    '{"data":{"id":902,"identifier":"W2902","needs_review":false},"hook":{"name":"before_doing"}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post 2>&1 >/dev/null)
  G21_RC=$?
  chmod 755 "$G21_D/.stride" 2>/dev/null
  assert_exit "21t: an unclearable loop state does not fail the claim" 0 "$G21_RC"
  assert_contains "21t: an unclearable loop state is announced on stderr" \
    "could not clear the loop state" "$G21_ERR"

  # 21u: a destination that is not a regular file is refused outright. `mv` onto
  # a DIRECTORY succeeds by relocating the temp INSIDE it, so the writer's own
  # failure branch never runs: the record lands where no reader looks and the
  # temp survives indefinitely. The guard exists because mv's success is the
  # wrong signal here.
  G21_D=$(g21_proj u)
  mkdir -p "$G21_D/$G21_STATE"
  G21_ERR=$(g21_input "s" "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post 2>&1 >/dev/null)
  G21_RC=$?
  assert_exit "21u: a non-regular-file destination does not fail the completion" 0 "$G21_RC"
  assert_contains "21u: a non-regular-file destination is announced on stderr" \
    "not a regular file" "$G21_ERR"
  assert_eq "21u: and no temp is relocated inside it" \
    "0" "$(find "$G21_D/$G21_STATE" -name 'loop-state.*' -type f 2>/dev/null | wc -l | tr -d ' ')"

  # 21v: an UNPARSABLE completion body is announced, because the completion may
  # have succeeded server-side with only the harness's copy cut — evidence lost,
  # indistinguishable from "nothing to record" unless said. A plain 422 stays
  # QUIET: it legitimately records nothing, and announcing every failed
  # completion would be noise that trains an operator to ignore the channel.
  G21_D=$(g21_proj v)
  G21_ERR=$(g21_input "s" "$G21_COMPLETE_CMD" '{"data":{"id":99,"ident TRUNCA' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post 2>&1 >/dev/null)
  assert_contains "21v: an unparsable completion body is announced" \
    "unparsable" "$G21_ERR"
  # A bare `false` is well-formed JSON, so it must NOT be announced as a parse
  # failure — the reason the test is `jq empty` and not `jq -e .`, whose exit
  # status comes from the VALUE rather than from whether it parsed.
  G21_D=$(g21_proj v3)
  G21_ERR=$(g21_input "s" "$G21_COMPLETE_CMD" 'false' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post 2>&1 >/dev/null)
  if echo "$G21_ERR" | grep -q 'unparsable'; then
    echo -e "  ${RED}FAIL${RESET}: 21v: a well-formed scalar body must not be announced as unparsable"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21v: a well-formed scalar body is not announced as unparsable"
    PASS=$((PASS + 1))
  fi
  G21_D=$(g21_proj v2)
  G21_ERR=$(g21_input "s" "$G21_COMPLETE_CMD" '{"errors":{"base":["bad"]}}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post 2>&1 >/dev/null)
  if echo "$G21_ERR" | grep -q 'unparsable'; then
    echo -e "  ${RED}FAIL${RESET}: 21v: a plain 422 must not be announced as unparsable"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21v: a plain 422 records nothing and stays quiet"
    PASS=$((PASS + 1))
  fi

  # 21w: AC5 — "both halves produce a byte-identical record" — asserted
  # MECHANICALLY rather than by matching per-field expectations in two suites
  # that never meet. The same input goes through both halves into two fresh
  # project dirs; completed_at's VALUE is normalised away (it is a wall clock,
  # so the two runs legitimately differ) but only after both raw files have been
  # regex-checked for the format, so the normalisation cannot mask a culture or
  # precision divergence. Everything else — key order, the boolean literal,
  # compact separators, the single trailing LF, the encoding — is inside the
  # compared bytes and needs no separate assertion.
  #
  # SKIP, never PASS, when pwsh is absent: a missing runtime must not be
  # mistaken for a passing parity check.
  if ! command -v pwsh > /dev/null 2>&1; then
    echo "  SKIP: 21w: pwsh not available — cross-half byte parity unverified"
  else
    G21_PS1="$SCRIPT_DIR/stride-hook.ps1"
    G21_DB=$(g21_proj w-bash)
    G21_DP=$(g21_proj w-ps1)
    G21_PARITY_IN=$(g21_input "sess-parity" "$G21_COMPLETE_CMD" "$G21_OK")
    printf '%s' "$G21_PARITY_IN" \
      | CLAUDE_PROJECT_DIR="$G21_DB" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
    printf '%s' "$G21_PARITY_IN" \
      | CLAUDE_PROJECT_DIR="$G21_DP" pwsh -NoProfile -File "$G21_PS1" post > /dev/null 2>&1
    G21_TS_RE='"completed_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"'
    G21_FMT_BASH=$(grep -Ec "$G21_TS_RE" "$G21_DB/$G21_STATE" 2>/dev/null || echo 0)
    G21_FMT_PS1=$(grep -Ec "$G21_TS_RE" "$G21_DP/$G21_STATE" 2>/dev/null || echo 0)
    assert_eq "21w: both halves emit the same completed_at format" \
      "1 1" "$G21_FMT_BASH $G21_FMT_PS1"
    sed -E 's/"completed_at":"[^"]*"/"completed_at":"X"/' "$G21_DB/$G21_STATE" \
      > "$G21_DB/norm.json" 2>/dev/null
    sed -E 's/"completed_at":"[^"]*"/"completed_at":"X"/' "$G21_DP/$G21_STATE" \
      > "$G21_DP/norm.json" 2>/dev/null
    if cmp -s "$G21_DB/norm.json" "$G21_DP/norm.json"; then
      echo -e "  ${GREEN}PASS${RESET}: 21w: both halves produce a byte-identical record"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 21w: the two halves produced different bytes"
      echo "    bash: $(od -c "$G21_DB/norm.json" 2>/dev/null | head -6)"
      echo "    ps1:  $(od -c "$G21_DP/norm.json" 2>/dev/null | head -6)"
      FAIL=$((FAIL + 1))
    fi
  fi

  # 21x: the charset gate must be BYTE-exact, not collation-based. A bracket
  # RANGE inside a `case` glob (`[!A-Za-z0-9_.:-]`) is collation-based and
  # accepts a non-ASCII letter on both bash 3.2/macOS and glibc, while the ps1
  # twin's `-cmatch '\A[A-Za-z0-9_.:-]+\z'` uses .NET ranges, which are
  # strictly code-point based and refuse it. That is an AC5 divergence in the
  # one gate whose entire job is to be identical — and it also falsifies the
  # premise that lets the halves ignore their encoding difference (jq emits raw
  # UTF-8 where ConvertTo-Json escapes non-ASCII, which can only be irrelevant
  # if no non-ASCII byte survives this gate). The bash half therefore ENUMERATES
  # its character set rather than using ranges.
  G21_D=$(g21_proj x)
  g21_input 'abcé' "$G21_COMPLETE_CMD" "$G21_OK" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21x: a non-ASCII session id is refused, not collated in" \
    "unknown" "$(jq -r '.session_id' "$G21_D/$G21_STATE" 2>/dev/null)"
  # The identifier runs through the same gate, and there the asymmetry is
  # larger: a half that accepted it would write a record where the other half
  # wrote none at all.
  G21_D=$(g21_proj x2)
  g21_input "s" "$G21_COMPLETE_CMD" \
    '{"data":{"id":99,"identifier":"W2147é","needs_review":false},"hooks":[{"name":"before_review"}]}' \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  if [ -f "$G21_D/$G21_STATE" ]; then
    echo -e "  ${RED}FAIL${RESET}: 21x: a non-ASCII identifier must be refused outright"
    echo "    wrote: $(cat "$G21_D/$G21_STATE")"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 21x: a non-ASCII identifier is refused outright"
    PASS=$((PASS + 1))
  fi

  # 21y: `tool_response.stdout` carrying a JSON OBJECT rather than a string.
  # bash resolves that field with `jq -r`, which re-serialises the object, so it
  # parses and records. A ps1 half that piped the PSCustomObject straight into
  # ConvertFrom-Json would stringify it to PowerShell's "@{...}" form, fail to
  # parse, record nothing, and announce an unparsable body — the second AC5
  # divergence, at exactly the parse boundary the task's pitfall names.
  # Unreachable with today's harness, which always sends stdout as a string.
  G21_D=$(g21_proj y)
  G21_OBJ_IN=$(jq -nc --arg c "$G21_COMPLETE_CMD" --argjson r "$G21_OK" \
    '{session_id:"sess-obj",tool_input:{command:$c},tool_response:{stdout:$r}}')
  printf '%s' "$G21_OBJ_IN" \
    | CLAUDE_PROJECT_DIR="$G21_D" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  assert_eq "21y: an object-shaped tool_response.stdout still records" \
    "W2147" "$(jq -r '.identifier' "$G21_D/$G21_STATE" 2>/dev/null)"
  if ! command -v pwsh > /dev/null 2>&1; then
    echo "  SKIP: 21y: pwsh not available — object-shaped parity unverified"
  else
    G21_DPY=$(g21_proj y-ps1)
    printf '%s' "$G21_OBJ_IN" \
      | CLAUDE_PROJECT_DIR="$G21_DPY" pwsh -NoProfile -File "$SCRIPT_DIR/stride-hook.ps1" post > /dev/null 2>&1
    sed -E 's/"completed_at":"[^"]*"/"completed_at":"X"/' "$G21_D/$G21_STATE" \
      > "$G21_D/objnorm.json" 2>/dev/null
    sed -E 's/"completed_at":"[^"]*"/"completed_at":"X"/' "$G21_DPY/$G21_STATE" \
      > "$G21_DPY/objnorm.json" 2>/dev/null
    if [ -s "$G21_D/objnorm.json" ] && cmp -s "$G21_D/objnorm.json" "$G21_DPY/objnorm.json"; then
      echo -e "  ${GREEN}PASS${RESET}: 21y: both halves record an object-shaped stdout identically"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: 21y: the halves diverge on an object-shaped stdout"
      echo "    bash: $(cat "$G21_D/objnorm.json" 2>/dev/null)"
      echo "    ps1:  $(cat "$G21_DPY/objnorm.json" 2>/dev/null)"
      FAIL=$((FAIL + 1))
    fi
  fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed (out of $TOTAL)"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
