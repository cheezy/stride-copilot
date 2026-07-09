#!/usr/bin/env bash
# stride-hook.sh — Bridges GitHub Copilot's PreToolUse/PostToolUse hooks to Stride .stride.md hook execution
#
# Called by GitHub Copilot's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives hook JSON on stdin, determines if the Bash command is a Stride API call,
# and if so, parses and executes the corresponding .stride.md section.
#
# Usage: echo '{"tool_input":{"command":"curl ..."}}' | stride-hook.sh <pre|post>
#
# Exit codes:
#   0 — Success (or not a Stride API call)
#   2 — Hook command failed (blocks the tool call in PreToolUse context)

set -uo pipefail

PHASE="${1:-}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
STRIDE_MD="$PROJECT_DIR/.stride.md"
ENV_CACHE="$PROJECT_DIR/.stride-env-cache"
# (D118) Canonical API-response snapshot. When present, after_goal detection and
# env extraction prefer it over the harness-truncatable tool_response.stdout.
# Best-effort fast path only — the reliability guarantee is D119's fresh call.
RESPONSE_FILE="$PROJECT_DIR/.stride/.last-api-response.json"

# --- Platform detection: delegate to PowerShell on native Windows ---
# Git Bash (OSTYPE=msys*) and WSL have full bash — run directly.
# Native Windows without bash (COMSPEC set, no OSTYPE) → delegate to .ps1
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-hook.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-hook.sh: Windows detected but stride-hook.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-hook.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT" "$PHASE"
fi

# Portable base64 decode of stdin (W1516). GNU/modern-macOS use -d; stock
# BSD/older macOS use -D. The input is captured first so the fallback re-feeds
# it after a failed first attempt (a naive `base64 -d || base64 -D` would send
# the already-consumed stdin as empty). Empty output when base64 is unavailable.
_b64_decode() {
  local _in
  _in=$(cat)
  command -v base64 > /dev/null 2>&1 || return 0
  printf '%s' "$_in" | base64 -d 2>/dev/null \
    || printf '%s' "$_in" | base64 -D 2>/dev/null \
    || true
}

# Compute the claim-time dirty baseline (W1516): one "<blobsha>\t<path>" line per
# path git currently reports as modified/staged/untracked-not-ignored, where the
# blob sha is git's content hash of the CURRENT file. A later capture compares a
# candidate path's current hash to this recorded hash to tell whether the path
# changed SINCE claim time — so a pre-existing, task-untouched edit is filtered
# while a pre-existing file the task later modifies still surfaces. Only hashes
# and paths are emitted — never file contents. Paths git quotes (special
# characters) are skipped (they fall through to being captured, the safe
# default). Runs from PROJECT_DIR, which is the repo root in Stride's use — the
# same assumption capture_changed_files already makes about path relativity.
_compute_dirty_baseline() {
  command -v git > /dev/null 2>&1 || return 0
  (
    cd "$PROJECT_DIR" 2>/dev/null || exit 0
    local _line _path _sha
    git status --porcelain 2>/dev/null | while IFS= read -r _line; do
      _path="${_line:3}"
      case "$_path" in *" -> "*) _path="${_path##* -> }" ;; esac
      case "$_path" in \"*) continue ;; esac
      [ -f "$_path" ] || continue
      _sha=$(git hash-object "$_path" 2>/dev/null) || continue
      [ -n "$_sha" ] && printf '%s\t%s\n' "$_sha" "$_path"
    done
  )
}

# --- Per-file diff capture (G148/W719 contract, Option D semantic) ---
# Emits a JSON array of `{path, diff}` entries to stdout, one per file that
# differs between $1 (base ref) and the agent's WORKING TREE at the time the
# function runs. The snapshot captures committed-since-base, staged-but-
# uncommitted, modified-but-unstaged, AND untracked-but-not-gitignored changes
# in a single pass — so reviewers see the agent's full working state at
# completion time, regardless of whether the agent committed before calling
# /complete. Truncates diffs over 500 lines with the contract marker; emits
# the binary placeholder for files git reports as binary in --numstat (tracked)
# or that contain a NUL byte (untracked). Falls back to HEAD~1 when the
# provided base is empty or unresolvable. Returns an empty array (and exit 0)
# for any degraded path (jq missing, git missing, not in a repo, no commits to
# diff) so callers can treat this strictly as "best-effort capture".
capture_changed_files() {
  local base="${1:-}"
  local max_lines=500
  local trunc_marker="[diff truncated at 500 lines]"
  local bin_placeholder="[binary file — no diff captured]"

  if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi

  if [ -z "$base" ] || ! git rev-parse --verify "$base" > /dev/null 2>&1; then
    if git rev-parse --verify "HEAD~1" > /dev/null 2>&1; then
      base="HEAD~1"
    else
      printf '[]\n'
      return 0
    fi
  fi

  # Tracked files that differ between base and the working tree (committed,
  # staged, and unstaged changes all surface in a single `git diff <base>`).
  local tracked_files
  tracked_files=$(git diff --name-only "$base" 2>/dev/null || printf '')

  # Untracked files not covered by .gitignore.
  local untracked_files
  untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null || printf '')

  # Combine; dedupe by path. Untracked entries should not overlap tracked
  # (git would report a path as one OR the other, not both), but the awk
  # `!seen` guard makes a single-entry-per-path invariant explicit.
  # (D67) Exclude the hook's OWN root bookkeeping artifacts from the snapshot:
  # .stride-diff-upload-state and .stride-changed-files.json otherwise pass both
  # the tracked-diff and untracked-not-gitignored nets and leak into a task's
  # changed_files. The match is anchored to the EXACT repo-root path (git
  # ls-files emits repo-root-relative paths), so a same-named file in a
  # subdirectory (e.g. sub/.stride-diff-upload-state) is still captured.
  # (W1609) Also hard-exclude the whole root-level .stride/ state directory — it
  # holds hook-internal artifacts (the orchestrator marker, the canonical
  # .last-api-response.json capture) that are gitignored in real projects but
  # must never appear in a task's changed_files even in repos that forgot to
  # ignore them.
  local all_files
  all_files=$(printf '%s\n%s\n' "$tracked_files" "$untracked_files" \
    | awk 'NF && $0 != ".stride-diff-upload-state" && $0 != ".stride-changed-files.json" && $0 !~ /^\.stride\// && !seen[$0]++')

  if [ -z "$all_files" ]; then
    printf '[]\n'
    return 0
  fi

  # numstat for tracked changes — used to detect binaries among tracked files
  # via the `- - <path>` marker. Untracked files are not in numstat; their
  # binary detection runs separately on file contents.
  local numstat
  numstat=$(git diff --numstat "$base" 2>/dev/null || printf '')

  local jsonl_file
  jsonl_file=$(mktemp)

  # (W1516) Decode the claim-time dirty baseline once. Each line is
  # "<blobsha>\t<path>"; a candidate path present here whose CURRENT content
  # hash still matches was already dirty at claim time and untouched by the
  # task, so it is filtered out of the snapshot below. Empty when no baseline
  # was recorded (clean claim, older env cache, or base64 unavailable).
  local _baseline_decoded=""
  if [ -n "${TASK_DIRTY_BASELINE:-}" ]; then
    _baseline_decoded=$(printf '%s' "$TASK_DIRTY_BASELINE" | _b64_decode)
  fi

  local file
  while IFS= read -r file; do
    [ -z "$file" ] && continue

    # (W1516) Skip a path that was already dirty at claim time AND whose content
    # is unchanged since — a pre-existing, task-untouched edit that must not be
    # misattributed to the agent. A baselined path whose current hash DIFFERS
    # (the task edited it further) is kept. A path absent from the baseline is a
    # genuine task change and is kept.
    if [ -n "$_baseline_decoded" ]; then
      local _base_sha _cur_sha
      _base_sha=$(printf '%s\n' "$_baseline_decoded" \
        | awk -F'\t' -v p="$file" '$2 == p { print $1; exit }')
      if [ -n "$_base_sha" ]; then
        _cur_sha=$(git hash-object "$file" 2>/dev/null || printf '')
        [ "$_cur_sha" = "$_base_sha" ] && continue
      fi
    fi

    # Determine whether this path is in the untracked list (membership lookup,
    # not just empty check — tracked_files and untracked_files were merged
    # above with dedupe).
    local is_untracked=0
    if [ -n "$untracked_files" ]; then
      local u
      while IFS= read -r u; do
        if [ "$u" = "$file" ]; then
          is_untracked=1
          break
        fi
      done <<< "$untracked_files"
    fi

    local is_binary=0
    local diff_text=""

    if [ "$is_untracked" -eq 1 ]; then
      # Untracked: synthesize a new-file unified patch by diffing the file
      # against /dev/null. `git diff --no-index` exits 1 when files differ —
      # that is the expected path here, so we ignore the exit code and
      # capture whatever stdout it produced. --no-color guards against
      # pager/color being inherited from the user's git config.
      #
      # Binary detection uses git's own determination: when --no-index sees
      # a binary file, it emits "Binary files /dev/null and <path> differ"
      # instead of a unified patch. Sniffing that prefix is more reliable
      # than a NUL-byte grep (bash truncates $'\0' to an empty pattern,
      # which matches every line and falsely flags text files as binary).
      diff_text=$(git diff --no-index --no-color /dev/null "$file" 2>/dev/null)
      # For new files, --no-index emits a header (`diff --git`,
      # `new file mode`, `index ...`) BEFORE the "Binary files ... differ"
      # sentinel line, so we have to check anywhere in the output rather
      # than just the prefix.
      if printf '%s\n' "$diff_text" | grep -q '^Binary files .* differ$'; then
        is_binary=1
      fi
    elif [ -n "$numstat" ]; then
      local nl added rest deleted path
      while IFS= read -r nl; do
        added="${nl%%	*}"
        rest="${nl#*	}"
        deleted="${rest%%	*}"
        path="${rest#*	}"
        if [ "$added" = "-" ] && [ "$deleted" = "-" ] && [ "$path" = "$file" ]; then
          is_binary=1
          break
        fi
      done <<< "$numstat"
    fi

    if [ "$is_binary" -eq 1 ]; then
      diff_text="$bin_placeholder"
    else
      if [ "$is_untracked" -eq 0 ]; then
        # Tracked: working-tree diff vs base (committed + staged + unstaged
        # changes all in one diff).
        diff_text=$(git diff "$base" -- "$file" 2>/dev/null || printf '')
      fi
      # diff_text for untracked was already captured above.
      local line_count=0
      if [ -n "$diff_text" ]; then
        local _no_nl="${diff_text//$'\n'/}"
        line_count=$(( ${#diff_text} - ${#_no_nl} + 1 ))
      fi
      if [ "$line_count" -gt "$max_lines" ]; then
        local truncated
        truncated=$(printf '%s\n' "$diff_text" | head -n $((max_lines - 1)))
        diff_text="${truncated}
${trunc_marker}"
      fi
    fi

    jq -n --arg path "$file" --arg diff "$diff_text" '{path: $path, diff: $diff}' >> "$jsonl_file"
  done <<< "$all_files"

  if [ -s "$jsonl_file" ]; then
    jq -s '.' < "$jsonl_file"
  else
    printf '[]\n'
  fi
  rm -f "$jsonl_file"
}

# Helper: resolve the Stride API base URL for the changed_files upload.
# Primary source is $PROJECT_DIR/.stride_auth.md (the same file the agent
# reads) — its `**API URL:** `<url>`` line. Falls back to a literal URL in the
# intercepted $COMMAND for back-compat when the auth file is absent. Prints the
# URL (or empty) on stdout.
resolve_stride_api_url() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _url=""
  if [ -f "$_auth" ]; then
    _url=$(grep -E '\*\*API URL:\*\*' "$_auth" | grep -oE 'https?://[A-Za-z0-9._:/-]+' | head -n 1 || true)
  fi
  if [ -z "$_url" ]; then
    _url=$(printf '%s' "${COMMAND:-}" | grep -oE 'https?://[A-Za-z0-9._-]+(:[0-9]+)?' | head -n 1 || true)
  fi
  printf '%s' "$_url"
}

# Helper: resolve the Stride API bearer token for the changed_files upload.
# Primary source is the production `**API Token:** `<token>`` line in
# $PROJECT_DIR/.stride_auth.md — deliberately NOT the `**Local API Token:**`
# line (the `**API Token:**` pattern does not match `**Local API Token:**`).
# Falls back to a literal `Bearer <token>` in the intercepted $COMMAND. Prints
# the token (or empty) on stdout; never logs it.
resolve_stride_api_token() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _tok=""
  if [ -f "$_auth" ]; then
    _tok=$(grep -E '\*\*API Token:\*\*' "$_auth" | grep -oE '`[^`]+`' | head -n 1 | tr -d '`' || true)
  fi
  if [ -z "$_tok" ]; then
    _tok=$(printf '%s' "${COMMAND:-}" | grep -oE 'Bearer +[A-Za-z0-9._+/=-]+' | head -n 1 | sed 's/^Bearer  *//' || true)
  fi
  printf '%s' "$_tok"
}

# Helper: PUT the on-disk per-file diff snapshot to the Stride server. We send
# the transport-encoded envelope {"changed_files":{"encoding":"base64","data":
# "<b64>"}} rather than the raw array so an edge request filter does not misread
# a code diff as an attack and drop the upload (D61). The server decodes it back
# to the same list. The base64 MUST be single-line so the value is valid inside
# the JSON string (strip any wrap newlines). When base64 is unavailable we fall
# back to the raw {"changed_files":[...]} shape — a bare top-level array would
# land at params['_json'] and persist as NULL. Prints the HTTP code on stdout
# ('000' on transport failure), warns on stderr for non-2xx, always returns 0.
# Shared by finalize_after_doing and the before_review self-heal (W1094) —
# callers MUST capture stdout or the code would leak into the hook's
# structured-JSON stdout contract.
upload_changed_files_snapshot() {
  local _task_id="$1" _api_base="$2" _token="$3"
  local _b64="" _http_code
  if command -v base64 > /dev/null 2>&1; then
    _b64=$(base64 < "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null | tr -d '\r\n')
  fi

  if [ -n "$_b64" ]; then
    _http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $_token" \
      -H 'Content-Type: application/json' \
      -d "{\"changed_files\":{\"encoding\":\"base64\",\"data\":\"$_b64\"}}" \
      "$_api_base/api/tasks/$_task_id/changed_files" 2>/dev/null || printf '000')
  else
    _http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $_token" \
      -H 'Content-Type: application/json' \
      -d "{\"changed_files\":$(cat "$PROJECT_DIR/.stride-changed-files.json")}" \
      "$_api_base/api/tasks/$_task_id/changed_files" 2>/dev/null || printf '000')
  fi

  # Surface a failed upload instead of dropping it silently. The diff is
  # non-fatal to completion, so we warn rather than abort.
  case "$_http_code" in
    2*) : ;;
    *)
      printf 'stride-hook: changed_files upload failed (HTTP %s) for task %s\n' \
        "$_http_code" "$_task_id" >&2
      ;;
  esac
  printf '%s' "$_http_code"
  return 0
}

# Helper: record the outcome of a changed_files PUT attempt (W1094) so the
# before_review self-heal can verify it on a fresh timeout budget. Task id
# and HTTP code ONLY — never the URL or bearer token (the file lives
# untracked in the project root alongside the other .stride artifacts).
record_diff_upload_state() {
  {
    printf 'task_id=%s\n' "$1"
    printf 'http_code=%s\n' "$2"
  } > "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
}

# Helper: persist the per-file diff snapshot, then fire-and-forget PUT it to
# the Stride server. Runs only for after_doing; capture and upload failures
# are both non-fatal. URL and token are resolved by resolve_stride_api_url /
# resolve_stride_api_token — preferring $PROJECT_DIR/.stride_auth.md so the
# upload works whether the agent's completion curl used literal values or shell
# variables ($STRIDE_API_URL / $STRIDE_API_TOKEN), with the $COMMAND literal
# extraction kept as a back-compat fallback.
# Placed before the early-return guards so tests can source this script and
# invoke finalize_after_doing in isolation.
finalize_after_doing() {
  if [ "${HOOK_NAME:-}" = "after_doing" ]; then
    local snapshot
    snapshot=$(capture_changed_files "${TASK_BASE_REF:-}" 2>/dev/null || printf '[]')
    printf '%s\n' "$snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true

    # No-op silently if any prerequisite is missing — preserves the on-disk
    # snapshot for legacy --argjson cf consumers.
    if [ "${HAS_JQ:-false}" = "true" ] && command -v curl > /dev/null 2>&1 && [ -n "${TASK_ID:-}" ]; then
      local _api_base _token
      _api_base=$(resolve_stride_api_url)
      _token=$(resolve_stride_api_token)
      if [ -n "$_api_base" ] && [ -n "$_token" ]; then
        # Upload via the shared D61 transport-envelope helper.
        local _http_code
        _http_code=$(upload_changed_files_snapshot "$TASK_ID" "$_api_base" "$_token")
        # (W1094) Record the outcome after EVERY PUT attempt so the
        # before_review self-heal can verify it on a fresh timeout budget.
        # A skipped PUT (missing preconditions) deliberately writes nothing:
        # missing state means "no healthy upload on record" and the retry
        # re-checks the same preconditions itself.
        record_diff_upload_state "$TASK_ID" "$_http_code"
      fi
    fi
  fi
}

# --- (W1094) Self-heal for the changed_files upload ---
# The after_doing gate can burn the whole hook budget, killing the process
# before or during the snapshot PUT — or the PUT itself returned non-2xx.
# before_review (PostToolUse on the same completion curl) runs on a FRESH
# budget, so it verifies the recorded outcome and re-captures + re-PUTs when no
# healthy upload is on record for the current task. Best-effort: never returns
# non-zero, and never touches the snapshot file unless a retry PUT is actually
# possible (preserves the on-disk snapshot for degraded environments and legacy
# consumers).
self_heal_changed_files_upload() {
  [ "${HOOK_NAME:-}" = "before_review" ] || return 0
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  command -v curl > /dev/null 2>&1 || return 0
  [ -n "${TASK_ID:-}" ] || return 0

  # Healthy 2xx recorded for THIS task → do not re-upload (snapshot
  # semantics anchor at after_doing time; avoid pointless API load).
  # Missing file, different task id, or non-2xx/empty code → retry.
  local _state_file="$PROJECT_DIR/.stride-diff-upload-state"
  local _state_task="" _state_code=""
  if [ -f "$_state_file" ]; then
    _state_task=$(grep '^task_id=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_code=$(grep '^http_code=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
  fi
  if [ "$_state_task" = "${TASK_ID:-}" ]; then
    case "$_state_code" in
      2*) return 0 ;;
    esac
  fi

  # Resolve credentials BEFORE overwriting the snapshot — when no PUT is
  # possible the stale on-disk snapshot must be left untouched.
  local _api_base _token
  _api_base=$(resolve_stride_api_url)
  _token=$(resolve_stride_api_token)
  if [ -z "$_api_base" ] || [ -z "$_token" ]; then
    return 0
  fi

  # Re-capture against the claim-time base ref. The subshell cd anchors git
  # to the project repo without disturbing the main script's cwd (the
  # before_review section's own `cd "$PROJECT_DIR"` has not run yet).
  local _snapshot _http_code
  _snapshot=$( (cd "$PROJECT_DIR" && capture_changed_files "${TASK_BASE_REF:-}") 2>/dev/null || printf '[]')
  printf '%s\n' "$_snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  _http_code=$(upload_changed_files_snapshot "$TASK_ID" "$_api_base" "$_token")
  record_diff_upload_state "$TASK_ID" "$_http_code"
  return 0
}

# --- Per-hook timeout budget (W1513) ---
# Seconds allotted to a whole `.stride.md` hook section, keyed on the section
# name. Mirrors the documented Hooks Reference table in the stride-workflow
# SKILL: after_doing = 120s; before_doing / before_review / after_review /
# after_goal (and any unrecognized section) = 60s. Every inner limit sits well
# under the 300s outer host budget declared in hooks/hooks.json, so enforcing
# them can never breach the host ceiling.
#
# A positive-integer STRIDE_HOOK_TIMEOUT_SECS overrides the budget for every
# section. It exists so the test suites can exercise the timeout path without
# waiting out the real 60/120s limits (and doubles as an advanced-tuning knob);
# an unset or non-numeric value is ignored and the documented defaults apply.
_hook_timeout_secs() {
  case "${STRIDE_HOOK_TIMEOUT_SECS:-}" in
    '' | *[!0-9]*) : ;;
    *) if [ "$STRIDE_HOOK_TIMEOUT_SECS" -gt 0 ]; then
         printf '%s' "$STRIDE_HOOK_TIMEOUT_SECS"
         return 0
       fi ;;
  esac
  case "$1" in
    after_doing) printf '120' ;;
    *)           printf '60' ;;
  esac
}

# Resolve a GNU-coreutils timeout utility once. Prefers `timeout`, then
# `gtimeout` (Homebrew coreutils installs the latter on macOS). Prints the
# resolved binary name, or nothing when neither exists — in which case the
# executor degrades to NO per-hook enforcement (only the 300s host budget
# applies). Stock macOS/BSD ship no timeout utility, so this graceful no-op is
# the documented fallback there rather than an error.
_resolve_timeout_bin() {
  if command -v timeout > /dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout > /dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

# Current wall-clock time in integer milliseconds, portably (W1514). The hook
# may run under bash 3.2 (no EPOCHREALTIME) and/or BSD date (no %N), so several
# high-resolution sources are tried in order, each guarded to accept only an
# all-digit result, before a whole-second last resort:
#   1. bash 5+ EPOCHREALTIME  — microsecond, no subprocess
#   2. GNU `date +%s%N`        — nanosecond (rejected on BSD, whose %N is literal)
#   3. perl Time::HiRes        — microsecond; core module, present on macOS/Linux
#   4. `date +%s` * 1000       — ms UNITS at second precision (never sub-second)
# This satisfies the duration_ms convention without depending on GNU-only
# `date +%s%N`.
_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    # "<secs>.<frac>"; the radix char is locale-dependent, so normalize , -> .
    local _er="${EPOCHREALTIME//,/.}"
    local _s="${_er%%.*}" _f="${_er#*.}"
    _f="${_f}000000"
    printf '%s%s' "$_s" "${_f:0:3}"
    return 0
  fi
  local _ns
  _ns=$(date +%s%N 2>/dev/null)
  case "$_ns" in
    '' | *[!0-9]*) : ;;
    *) printf '%s' "$(( _ns / 1000000 ))"; return 0 ;;
  esac
  if command -v perl > /dev/null 2>&1; then
    local _pms
    _pms=$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)
    case "$_pms" in
      '' | *[!0-9]*) : ;;
      *) printf '%s' "$_pms"; return 0 ;;
    esac
  fi
  printf '%s000' "$(date +%s)"
}

# True (exit 0) when a line ends with a shell line-continuation backslash
# (W1515). A trailing backslash continues the command onto the next line ONLY
# when it is unescaped — i.e. the run of trailing backslashes has ODD length.
# An even run (`\\`, `\\\\`, ...) is a literal backslash and does NOT continue,
# so genuine literal backslashes are left intact. Trailing whitespace is
# significant (a backslash followed by a space does not continue), matching the
# shell; leading whitespace was already trimmed by the caller.
_has_line_continuation() {
  local _s="$1" _n=0
  while [ "${_s%\\}" != "$_s" ]; do
    _s="${_s%\\}"
    _n=$((_n + 1))
  done
  [ $(( _n % 2 )) -eq 1 ]
}

# --- Parse and execute one .stride.md hook section ---
# Takes a single section name (e.g. "before_doing", "after_goal") and:
#   1. Parses the first `## <section>` block from .stride.md (first-wins,
#      single ```bash fence, identical to the four-hook routes).
#   2. Returns 0 immediately when the section is missing OR the fenced body
#      is empty — back-compat no-op for older .stride.md files.
#   3. Otherwise executes each command sequentially; on the first non-zero
#      exit, emits the structured failed-JSON (or the plain-text fallback
#      when $HAS_JQ=false) and returns 2.
#   4. On all-success, emits the structured success-JSON (jq-only) and
#      returns 0.
# Reuses the global $HAS_JQ, $STRIDE_MD, $PROJECT_DIR, and the file-scope
# `finalize_after_doing` hook (which gates internally on the GLOBAL $HOOK_NAME,
# so calling this for "after_goal" does NOT re-trigger the after_doing snapshot).
run_stride_section() {
  local _section="$1"
  local _commands=""
  local _found=0
  local _capture=0
  local _line _heading

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _heading="${_line#\#\# }"
        _heading="${_heading%"${_heading##*[![:space:]]}"}"
        [ "$_heading" = "$_section" ] && _found=1
        continue
        ;;
    esac
    if [ "$_found" -eq 1 ]; then
      case "$_line" in
        '```bash'*) _capture=1; continue ;;
        '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
      esac
      [ "$_capture" -eq 1 ] && _commands="${_commands}${_line}
"
    fi
  done < "$STRIDE_MD"

  if [ -z "$_commands" ]; then
    finalize_after_doing
    return 0
  fi

  # Build the command list, joining backslash line-continuations (W1515) so a
  # multi-line command (e.g. a long `gh pr create` split with trailing `\`) runs
  # as ONE command instead of fragmented pieces. Blank/comment skipping applies
  # only when starting a fresh command (_pending empty); a line pulled in by a
  # continuation is appended verbatim, exactly as the shell would join it. For
  # non-continued input every branch reduces to the pre-W1515 behavior, so
  # single-line commands parse byte-identically.
  local _cmd _trimmed _pending=""
  local _cmd_list
  _cmd_list=()
  while IFS= read -r _cmd; do
    _trimmed="${_cmd#"${_cmd%%[![:space:]]*}"}"
    if [ -n "$_pending" ]; then
      _trimmed="${_pending}${_trimmed}"
      _pending=""
    else
      [ -z "$_trimmed" ] && continue
      case "$_trimmed" in \#*) continue ;; esac
    fi
    if _has_line_continuation "$_trimmed"; then
      # Drop the single continuation backslash and hold the rest for the next
      # line (any literal backslashes preceding it are preserved).
      _pending="${_trimmed%\\}"
      continue
    fi
    _cmd_list+=("$_trimmed")
  done <<< "$_commands"
  # Flush a dangling continuation (final fenced line ended with a backslash) so
  # the command is still run rather than silently dropped.
  [ -n "$_pending" ] && _cmd_list+=("$_pending")

  if [ ${#_cmd_list[@]} -eq 0 ]; then
    finalize_after_doing
    return 0
  fi

  cd "$PROJECT_DIR"

  # Early per-file diff snapshot (W1093) — capture and upload BEFORE the gate
  # commands run, so a slow or failing after_doing gate can't kill the process
  # before the diff upload completes. finalize_after_doing gates internally on
  # the GLOBAL $HOOK_NAME, so this is inert for after_goal (and every
  # non-after_doing hook). The post-loop call below stays as a refresh that
  # picks up any files the gate commands themselves changed.
  finalize_after_doing

  local _completed_file _output_file
  _completed_file=$(mktemp)
  # Parallel to _completed_file: one JSON object per successful command holding
  # its tail-truncated stdout/stderr, slurped into the success JSON's
  # commands_output array (D65). Keeps passing-gate output off fd 2 so Claude
  # Code does not render it under a false "PreToolUse:Bash hook error" label.
  _output_file=$(mktemp)
  # _start_secs (whole seconds) drives the W1513 per-hook timeout elapsed math;
  # _start_ms (W1514) drives the millisecond duration_ms reported in the success
  # JSON — the two clocks are independent so timeout budgeting keeps its cheap
  # second granularity while telemetry gains real sub-second fidelity.
  local _start_secs _start_ms
  _start_secs=$(date +%s)
  _start_ms=$(_now_ms)
  local _cmd_index=0
  local _cmd_total=${#_cmd_list[@]}
  local _cmd_stdout_file _cmd_stderr_file _cmd_exit _cmd_stdout _cmd_stderr
  local _remaining_file _completed_json _remaining_json _output_json _duration_ms _i
  # Per-hook timeout budget (W1513): the whole section shares _hook_limit
  # seconds; each command runs under the time REMAINING so the section total
  # can never exceed the limit. _timeout_bin is empty when no timeout utility
  # exists (enforcement disabled, only the 300s host budget applies).
  local _hook_limit _timeout_bin _elapsed _time_remaining
  _hook_limit=$(_hook_timeout_secs "$_section")
  _timeout_bin=$(_resolve_timeout_bin)

  for _trimmed in "${_cmd_list[@]}"; do
    _cmd_stdout_file=$(mktemp)
    _cmd_stderr_file=$(mktemp)

    # Relax `set -u` and `pipefail` for the user's command so that a reference
    # to an unset env var doesn't silently abort execution before the actual
    # command runs; restore the strict flags immediately afterward.
    set +uo pipefail
    if [ -n "$_timeout_bin" ]; then
      # Enforce the per-hook budget. Each command is capped at the time
      # REMAINING in the section's budget, so the section as a whole can never
      # outlast _hook_limit (and thus never the 300s host ceiling). `timeout`
      # sends SIGTERM on expiry and exits 124 — a genuine failure that flows
      # through the failed-JSON path below, preserving the after_doing
      # PreToolUse exit-2 block (a timeout is a failure, not a silent pass).
      # Running via `bash -c` isolates each command; exported env (TASK_*,
      # GOAL_*, etc.) is inherited so hook commands see the same variables.
      # NOTE: per-command shell state does NOT persist across commands when
      # enforcement is active — a bare `cd subdir` or a non-exported var set on
      # one line is not visible to the next (each runs in its own subshell). The
      # no-timeout `eval` branch below preserves such state. Hook sections use
      # independent commands, so this divergence is benign in practice.
      _elapsed=$(( $(date +%s) - _start_secs ))
      _time_remaining=$(( _hook_limit - _elapsed ))
      [ "$_time_remaining" -lt 1 ] && _time_remaining=1
      "$_timeout_bin" "$_time_remaining" bash -c "$_trimmed" \
        > "$_cmd_stdout_file" 2> "$_cmd_stderr_file"
      _cmd_exit=$?
    else
      # No timeout utility available — degrade to no per-hook enforcement (only
      # the 300s hooks.json host budget applies). In-process eval preserves the
      # pre-W1513 behavior, including cross-command shell state.
      eval "$_trimmed" > "$_cmd_stdout_file" 2> "$_cmd_stderr_file"
      _cmd_exit=$?
    fi
    set -uo pipefail

    # Make a budget timeout self-describing (W1513). `timeout` exits 124 on
    # expiry; annotate stderr so the failed-JSON and the fd2 message name the
    # cause. exit_code stays 124 so the hook-diagnostician still parses it.
    if [ "$_cmd_exit" -eq 124 ] && [ -n "$_timeout_bin" ]; then
      printf 'stride-hook: %s hook command exceeded its %ss per-hook timeout budget\n' \
        "$_section" "$_hook_limit" >> "$_cmd_stderr_file"
    fi

    if [ "$_cmd_exit" -eq 0 ]; then
      echo "$_trimmed" >> "$_completed_file"
      # Do NOT cat the passing command's output to fd 2: Claude Code renders any
      # hook stderr under a red "PreToolUse:Bash hook error" label even on exit
      # 0 (D65). Instead capture a tail-truncated copy — same -50 cap as the
      # failure path — into _output_file as a JSON object, folded into the
      # success JSON's commands_output array below so agents keep visibility.
      if [ "$HAS_JQ" = "true" ]; then
        _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
        _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
        jq -n \
          --arg command "$_trimmed" \
          --arg stdout "$_cmd_stdout" \
          --arg stderr "$_cmd_stderr" \
          '{command: $command, stdout: $stdout, stderr: $stderr}' >> "$_output_file"
      fi
    else
      _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
      _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
      rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"

      _remaining_file=$(mktemp)
      if [ $((_cmd_index + 1)) -lt $_cmd_total ]; then
        for ((_i = _cmd_index + 1; _i < _cmd_total; _i++)); do
          echo "${_cmd_list[$_i]}" >> "$_remaining_file"
        done
      fi

      if [ "$HAS_JQ" = "true" ]; then
        _completed_json=$(jq -R . < "$_completed_file" | jq -s . 2>/dev/null || echo "[]")
        _remaining_json=$(jq -R . < "$_remaining_file" | jq -s . 2>/dev/null || echo "[]")

        jq -n \
          --arg hook "$_section" \
          --arg failed "$_trimmed" \
          --argjson index "$_cmd_index" \
          --argjson exit_code "$_cmd_exit" \
          --arg stdout "$_cmd_stdout" \
          --arg stderr "$_cmd_stderr" \
          --argjson completed "$_completed_json" \
          --argjson remaining "$_remaining_json" \
          '{
            hook: $hook,
            status: "failed",
            failed_command: $failed,
            command_index: $index,
            exit_code: $exit_code,
            stdout: $stdout,
            stderr: $stderr,
            commands_completed: $completed,
            commands_remaining: $remaining
          }'
      else
        echo "HOOK=$_section STATUS=failed COMMAND=$_trimmed EXIT=$_cmd_exit"
      fi

      echo "Stride $_section hook failed on command $((_cmd_index + 1))/$_cmd_total: $_trimmed" >&2
      [ -n "$_cmd_stderr" ] && echo "$_cmd_stderr" >&2
      rm -f "$_completed_file" "$_remaining_file" "$_output_file"
      return 2
    fi

    rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"
    _cmd_index=$((_cmd_index + 1))
  done

  # Per-file diff snapshot refresh (G148/W719; early call added in W1093) —
  # re-capture after the gate commands succeeded so files they changed are
  # included. No-op outside after_doing (gates on the GLOBAL $HOOK_NAME);
  # calling this for "after_goal" does NOT retrigger.
  finalize_after_doing

  _duration_ms=$(( $(_now_ms) - _start_ms ))

  if [ "$HAS_JQ" = "true" ]; then
    _completed_json=$(jq -R . < "$_completed_file" | jq -s . 2>/dev/null || echo "[]")
    _output_json=$(jq -s . < "$_output_file" 2>/dev/null || echo "[]")

    jq -n \
      --arg hook "$_section" \
      --argjson duration_ms "$_duration_ms" \
      --argjson completed "$_completed_json" \
      --argjson outputs "$_output_json" \
      '{
        hook: $hook,
        status: "success",
        commands_completed: $completed,
        commands_output: $outputs,
        duration_ms: $duration_ms
      }'
  fi

  rm -f "$_completed_file" "$_output_file"
  return 0
}

# --- Canonical response-file fast path (D118) ---
# The harness can truncate a large /complete tool_response.stdout mid-JSON,
# which silently breaks after_goal detection and env extraction. When the agent
# (or a PreToolUse capture) has written the full API response to the canonical
# file ($RESPONSE_FILE), prefer it over the truncatable stdout. Prints the
# file's JSON when it is present AND parses as valid JSON; prints nothing
# otherwise so the caller falls back to the tool_response.stdout parse. Gated on
# $HAS_JQ — the validity check needs jq, and a garbage/truncated file must never
# shadow the stdout fallback. Best-effort only: a stale-but-valid file is used
# as-is (D119's fresh call is the reliability guarantee, not this fast path).
read_canonical_response() {
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "${RESPONSE_FILE:-}" ] || return 0
  [ -f "$RESPONSE_FILE" ] || return 0

  local _content
  _content=$(cat "$RESPONSE_FILE" 2>/dev/null) || return 0
  [ -n "$_content" ] || return 0

  # Validate before trusting it — a truncated/garbage file must fall through.
  echo "$_content" | jq -e . > /dev/null 2>&1 || return 0

  printf '%s' "$_content"
}

# (W1609) Unwrap the API payload string from a hook input's .tool_response: the
# GitHub Copilot Bash tool wraps it as {"stdout":"<json>"}, other harnesses
# carry the API JSON directly. Prints the unwrapped payload (possibly
# truncated), or nothing. Single-sourced so the read side
# (extract_response_payload) and the write side (capture_canonical_response)
# share one unwrap and cannot diverge. Gated on $HAS_JQ.
unwrap_tool_response() {
  local _hook_input="$1"
  local _response _payload

  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "$_hook_input" ] || return 0

  _response=$(echo "$_hook_input" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
  [ -n "$_response" ] || return 0

  if echo "$_response" | jq -e 'type == "object" and has("stdout")' > /dev/null 2>&1; then
    _payload=$(echo "$_response" | jq -r '.stdout // ""' 2>/dev/null)
  else
    _payload="$_response"
  fi

  printf '%s' "$_payload"
}

# (W1609) Capture the current API response to the canonical file. The hook is a
# PostToolUse observer, so the freshest untruncated data it can persist is THIS
# call's tool_response.stdout when it parses as complete JSON. Writing it keeps
# $RESPONSE_FILE current for the file-first resolver below: the claim env-cache
# refresh and after_goal detection then read the CURRENT call's data instead of
# a stale prior-call file. When the current stdout is itself truncated the file
# is left untouched, so a value written out-of-band (a `curl ... | tee
# "$RESPONSE_FILE"` / `--output` passthrough on the completion/claim/
# mark_reviewed curls, or a future PreToolUse capture) survives as the
# best-effort source. Only complete, valid JSON is ever written — a truncated
# blob must never overwrite a good file. Gated on $HAS_JQ.
capture_canonical_response() {
  local _hook_input="$1"
  local _payload

  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "${RESPONSE_FILE:-}" ] || return 0

  _payload=$(unwrap_tool_response "$_hook_input")
  [ -n "$_payload" ] || return 0
  # Only persist a COMPLETE, valid API JSON — a truncated blob must never
  # overwrite a good (e.g. curl-tee'd) canonical file.
  echo "$_payload" | jq -e . > /dev/null 2>&1 || return 0

  mkdir -p "$(dirname "$RESPONSE_FILE")" 2>/dev/null || return 0
  printf '%s' "$_payload" > "$RESPONSE_FILE" 2>/dev/null || true
}

# (D118/W1609) The single shared response resolver. Source order:
#   1. the canonical response file (survives harness truncation) — D118
#   2. tool_response.stdout, unwrapped from the Copilot {"stdout":...} shape
#      or taken raw (other harnesses), when it is complete valid JSON
#   3. the W1086 persisted-output file named by a "Full output saved to: <path>"
#      stdout notice, when stdout was too large to inline
# Falls back to the best-effort (possibly truncated) stdout blob as a last
# resort; callers jq-guard their own use, so a truncated blob degrades cleanly.
# Reused by response_has_after_goal, export_after_goal_env, AND the claim
# env-cache/TASK_BASE_REF refresh so none of them can diverge (W1609 pitfall).
extract_response_payload() {
  local _hook_input="$1"
  local _payload _notice _persist_line _persist_path _persist_json

  [ "$HAS_JQ" = "true" ] || return 0

  # (D118) Fast path — prefer the untruncated canonical response file.
  _payload=$(read_canonical_response)
  if [ -n "$_payload" ]; then
    printf '%s' "$_payload"
    return 0
  fi

  # Unwrap the current call's stdout payload (shared with capture_canonical_response).
  _payload=$(unwrap_tool_response "$_hook_input")
  [ -n "$_payload" ] || return 0

  # Use the stdout payload when it is complete, valid JSON.
  if echo "$_payload" | jq -e . > /dev/null 2>&1; then
    printf '%s' "$_payload"
    return 0
  fi

  # (W1086) Shape 3: persisted-output file fallback. When the response is large,
  # the harness writes the tool output to a file and leaves only a notice —
  # "Full output saved to: <absolute path>" — in stdout. Recover the API JSON by
  # reading that file. The path is harness-controlled, so require an existing
  # regular file and parse it with jq only — never source, eval, or write to it.
  _notice="$_payload"
  if printf '%s' "$_notice" | grep -qi 'saved to'; then
    # Keep the path from its first "/" to end of the notice line so a path
    # containing spaces survives; tolerate the notice wrapping it in quotes.
    _persist_line=$(printf '%s\n' "$_notice" | grep -i 'saved to' | head -1)
    _persist_path="/${_persist_line#*/}"
    _persist_path="${_persist_path%\"}"
    if [ -n "$_persist_line" ] && [ -f "$_persist_path" ]; then
      _persist_json=$(cat "$_persist_path" 2>/dev/null || echo "")
      if [ -n "$_persist_json" ] && echo "$_persist_json" | jq -e . > /dev/null 2>&1; then
        printf '%s' "$_persist_json"
        return 0
      fi
    fi
  fi

  # Best-effort last resort: whatever we unwrapped (possibly truncated).
  printf '%s' "$_payload"
}

# Detect an `after_goal` entry in the response's `hooks` array. Handles both
# the host's wrapped form (`tool_response.stdout` is a JSON string whose
# body contains the response) and raw-API-JSON form. Returns 0 when an entry
# with name == "after_goal" is found, 1 otherwise. Gated on $HAS_JQ —
# environments without jq cannot parse the response and degrade cleanly.
#
# (D118/W1609) Payload source order is owned by the single shared resolver
# extract_response_payload: canonical response file first (survives harness
# truncation), then the tool_response.stdout unwrap, then the W1086 persisted-
# output file. Delegating here keeps after_goal detection, env forwarding, and
# the claim env-cache refresh on ONE resolver so they can never diverge.
# (D119) Pure jq predicate on an ALREADY-RESOLVED payload string (no $INPUT
# unwrap): does it carry an after_goal hook entry? Single-sourced so
# response_has_after_goal and route_after_goal share one after_goal detection
# expression and can never diverge.
payload_has_after_goal() {
  local _payload="$1"
  [ "${HAS_JQ:-false}" = "true" ] || return 1
  [ -n "$_payload" ] || return 1
  echo "$_payload" \
    | jq -e '(.hooks // []) | map(select(.name == "after_goal")) | length > 0' \
        > /dev/null 2>&1
}

response_has_after_goal() {
  local _hook_input="$1"

  [ "$HAS_JQ" = "true" ] || return 1

  payload_has_after_goal "$(extract_response_payload "$_hook_input")"
}

# Export the server-supplied `env` object from the response's after_goal hook
# entry (W1512). The 2.11.0 CHANGELOG and stride-workflow SKILL promise that
# GOAL_ID/GOAL_IDENTIFIER/GOAL_TITLE/GOAL_DESCRIPTION (plus BOARD_*/COLUMN_*/
# AGENT_NAME when present) reach the after_goal child process, but nothing ever
# extracted them — so a `## after_goal` section that references $GOAL_ID ran
# with it empty. This function takes an ALREADY-RESOLVED response payload (the
# caller resolves it once through extract_response_payload, or synthesizes it —
# D119's fresh-call path does), selects the FIRST after_goal hook entry's `env`
# object, and exports each key VERBATIM into the current process environment so
# the subsequent run_stride_section "after_goal" (which eval's the section's
# commands) sees them.
#
# (D119) Takes a resolved payload — NOT a hook input — so the D118 fast path and
# the D119 fresh-call path can both feed run_after_goal_section a payload they
# already resolved (the fast path via extract_response_payload, the fresh call
# via the synthetic after_goal-entry wrapper it builds from the endpoint env).
#
# Contract:
#   - Values are copied verbatim from the server payload; this NEVER invents,
#     derives, or looks up any key client-side (in particular it never
#     synthesizes GOAL_ID from the child task's parent_id).
#   - A missing env object, an empty env object, or missing keys is a clean
#     no-op — not an error.
#   - Gated on $HAS_JQ: without jq the payload cannot be parsed, so the export
#     degrades to nothing (matching response_has_after_goal's degrade path).
export_after_goal_env() {
  local _payload="$1"
  local _env

  [ "$HAS_JQ" = "true" ] || return 0
  [ -n "$_payload" ] || return 0

  # The `env` object from the FIRST after_goal hook entry, compacted to one
  # line. `first(...)` mirrors response_has_after_goal's selection; the `// {}`
  # collapses "no after_goal entry" and "entry without env" to an empty object.
  _env=$(echo "$_payload" \
    | jq -c 'first((.hooks // [])[] | select(.name == "after_goal") | .env) // {}' \
        2>/dev/null || echo "{}")
  [ -n "$_env" ] || return 0
  [ "$_env" = "null" ] && return 0

  # Export each key VERBATIM. Iterate the key names (insertion order
  # preserved via keys_unsorted) and pull each value back with a targeted
  # jq lookup, so a value containing spaces stays intact and
  # `export "$k=$v"` assigns without eval'ing the payload. An empty env
  # object yields no keys -> no iterations.
  local _keys _key _val
  _keys=$(echo "$_env" | jq -r 'keys_unsorted[]' 2>/dev/null || printf '')
  [ -n "$_keys" ] || return 0
  while IFS= read -r _key; do
    [ -n "$_key" ] || continue
    _val=$(echo "$_env" | jq -r --arg k "$_key" '.[$k] | if . == null then "" else tostring end' 2>/dev/null || printf '')
    export "$_key=$_val"
  done <<< "$_keys"
}

# --- After-goal execution (shared by the D118 fast path and the D119 fresh call) ---
# (D119) Export GOAL_* from the given ALREADY-RESOLVED payload and run the local
# ## after_goal section as a blocking hook, restoring HOOK_NAME afterward.
# Centralised so both detection paths run the section identically — and, because
# route_after_goal invokes exactly one path, exactly once (de-dup).
run_after_goal_section() {
  local _payload="$1"
  # (W1512) Export GOAL_* (server-supplied) before the section runs. The section
  # observes HOOK_NAME=after_goal per the documented contract; the routed value
  # is restored afterwards because the cleanup gate keys on it.
  export_after_goal_env "$_payload"
  local _routed_hook_name="$HOOK_NAME"
  export HOOK_NAME="after_goal"
  run_stride_section "after_goal" || true
  HOOK_NAME="$_routed_hook_name"
  export HOOK_NAME
}

# (D119) Reliability guarantee. Detect after_goal via a fresh, hook-initiated
# GET /api/tasks/:id/after_goal_status (the compact endpoint from kanban W1613).
# A curl the hook spawns is NOT subject to the Bash-tool output truncation that
# can gut the agent-handed /complete response, and it needs zero agent
# cooperation. Runs the ## after_goal section from the endpoint's compact GOAL_*
# env when after_goal_armed is true. Best-effort: a missing prerequisite
# (jq/curl/TASK_ID/URL/token) or an unreachable / non-JSON endpoint degrades to a
# clean no-op — the server's grace-window worker still completes the goal. Never
# echoes the token. Returns 0 when it reached a definitive answer, 1 when it
# could not run.
detect_after_goal_via_api() {
  [ "${HAS_JQ:-false}" = "true" ] || return 1
  command -v curl > /dev/null 2>&1 || return 1
  [ -n "${TASK_ID:-}" ] || return 1

  local _api_base _token _resp _armed _payload
  _api_base=$(resolve_stride_api_url)
  _token=$(resolve_stride_api_token)
  [ -n "$_api_base" ] && [ -n "$_token" ] || return 1

  _resp=$(curl -s --max-time 10 \
    -H "Authorization: Bearer $_token" \
    "$_api_base/api/tasks/$TASK_ID/after_goal_status" 2>/dev/null || printf '')
  [ -n "$_resp" ] || return 1
  echo "$_resp" | jq -e . > /dev/null 2>&1 || return 1

  _armed=$(echo "$_resp" | jq -r '.after_goal_armed // false' 2>/dev/null || printf 'false')
  # Reached the server and got a definitive answer. Not armed → clean success.
  [ "$_armed" = "true" ] || return 0

  # Wrap the endpoint's flat env into the after_goal-hook-entry shape that
  # export_after_goal_env consumes; carry goal_id as data.parent_id so a
  # GOAL_ID parent-id fallback still applies if env omits it.
  _payload=$(echo "$_resp" \
    | jq -c '{hooks: [{name: "after_goal", env: (.env // {})}], data: {parent_id: .goal_id}}' \
        2>/dev/null || printf '')
  [ -n "$_payload" ] || return 1

  run_after_goal_section "$_payload"
  return 0
}

# --- After-goal routing (W788 / D118 / D119) ---
# Decide whether to run the local ## after_goal section after a /complete or
# /mark_reviewed post. Two mutually-exclusive paths, so the section runs at most
# once (de-dup):
#   * Fast path (D118): when the handed payload is COMPLETE, valid JSON it
#     answers definitively — armed runs the section, parseable-but-absent means
#     definitively not armed. No extra round-trip either way.
#   * Reliability guarantee (D119): when the handed payload is truncated,
#     absent, or unparseable, ask the server directly with a hook-spawned curl.
route_after_goal() {
  local _payload="$1"

  [ "${HAS_JQ:-false}" = "true" ] || return 0

  if [ -n "$_payload" ] && echo "$_payload" | jq -e . > /dev/null 2>&1; then
    payload_has_after_goal "$_payload" && run_after_goal_section "$_payload"
    return 0
  fi

  detect_after_goal_via_api || true
}

# Exit early if no phase argument or no .stride.md. Placed AFTER the
# capture_changed_files, finalize_after_doing, run_stride_section,
# response_has_after_goal, and export_after_goal_env definitions so tests can
# source this script to use the functions in isolation.
if [ -z "$PHASE" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ ! -f "$STRIDE_MD" ]; then
  return 0 2>/dev/null || exit 0
fi

# Read GitHub Copilot hook input from stdin
INPUT=$(cat)

# Detect jq availability once
HAS_JQ=false
command -v jq > /dev/null 2>&1 && HAS_JQ=true

# Extract the Bash command from hook JSON
# Try jq first, fall back to pure bash for environments without jq
if [ "$HAS_JQ" = "true" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
else
  # Pure bash JSON extraction: find "command" : "value"
  _tmp="${INPUT#*\"command\"}"
  # If the expansion didn't change, the key wasn't found
  if [ "$_tmp" = "$INPUT" ]; then
    COMMAND=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    COMMAND="${_tmp%%\"*}"
  fi
fi

[ -n "$COMMAND" ] || exit 0

# --- Determine which Stride hook to run ---
# Routing:
#   post + /api/tasks/claim        → before_doing
#   pre  + /api/tasks/:id/complete → after_doing  (blocks completion if it fails)
#   post + /api/tasks/:id/complete → before_review
#   post + /api/tasks/:id/mark_reviewed → after_review

HOOK_NAME=""

case "$PHASE" in
  post)
    case "$COMMAND" in
      */api/tasks/claim*)          HOOK_NAME="before_doing" ;;
      */api/tasks/*/mark_reviewed*) HOOK_NAME="after_review" ;;
      */api/tasks/*/complete*)      HOOK_NAME="before_review" ;;
    esac
    ;;
  pre)
    case "$COMMAND" in
      */api/tasks/*/complete*) HOOK_NAME="after_doing" ;;
    esac
    ;;
esac

# Not a Stride API call — exit cleanly
[ -n "$HOOK_NAME" ] || exit 0

# (W1609) Persist THIS call's response to the canonical file before the claim
# env-cache refresh and env forwarding read it, so both resolve the current
# call's data (file-first) rather than a stale prior-call file. A no-op when the
# stdout is truncated (leaves any out-of-band tee/--output copy intact) or when
# this is a pre-phase call with no tool_response yet.
if [ "$PHASE" = "post" ]; then
  capture_canonical_response "$INPUT"
fi

# --- Environment variable caching ---
# After a successful claim (before_doing), extract task metadata from the API
# response and cache it. All subsequent hooks load the cache so .stride.md
# commands can reference $TASK_IDENTIFIER, $TASK_TITLE, etc.

if [ "$HOOK_NAME" = "before_doing" ] && [ "$HAS_JQ" = "true" ]; then
  # (W1609) Resolve the claim response through the ONE shared resolver
  # (extract_response_payload): canonical response file first, then the
  # tool_response.stdout unwrap, then the W1086 persisted-output file. This is
  # the same resolver after_goal detection and env forwarding use, so a
  # harness-truncated claim stdout no longer diverges — when a canonical
  # response file is present (the capture above, a curl tee, or D119) the full
  # task JSON is recovered and TASK_BASE_REF / the changed_files scope stay
  # correct instead of silently degrading to a stale base ref.
  _claim_payload=$(extract_response_payload "$INPUT")
  TASK_JSON=""
  if [ -n "$_claim_payload" ]; then
    if echo "$_claim_payload" | jq -e '.data.id' > /dev/null 2>&1; then
      TASK_JSON=$(echo "$_claim_payload" | jq -c '.data' 2>/dev/null)
    elif echo "$_claim_payload" | jq -e '.id' > /dev/null 2>&1; then
      TASK_JSON="$_claim_payload"
    fi
  fi

  # (W1516) Snapshot which paths are ALREADY dirty at claim time, base64-encoded
  # as a single safe env-cache line (many paths, no special-char breakage, no
  # file contents — only hashes). capture_changed_files subtracts this baseline
  # so unrelated pre-existing edits are never misattributed to the agent.
  _dirty_baseline_b64=$(_compute_dirty_baseline | base64 2>/dev/null | tr -d '\r\n')

  if [ -n "$TASK_JSON" ]; then
    # Values are single-quoted to handle spaces in titles/descriptions.
    # TASK_BASE_REF anchors per-file diff capture to the commit HEAD pointed
    # at when the task was claimed (consumed by capture_changed_files at
    # after_doing time).
    _base_ref=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || true)
    {
      echo "TASK_ID='$(echo "$TASK_JSON" | jq -r '.id // empty')'"
      echo "TASK_IDENTIFIER='$(echo "$TASK_JSON" | jq -r '.identifier // empty')'"
      echo "TASK_TITLE='$(echo "$TASK_JSON" | jq -r '.title // empty')'"
      echo "TASK_STATUS='$(echo "$TASK_JSON" | jq -r '.status // empty')'"
      echo "TASK_COMPLEXITY='$(echo "$TASK_JSON" | jq -r '.complexity // empty')'"
      echo "TASK_PRIORITY='$(echo "$TASK_JSON" | jq -r '.priority // empty')'"
      echo "TASK_BASE_REF='$_base_ref'"
      echo "TASK_DIRTY_BASELINE='$_dirty_baseline_b64'"
    } > "$ENV_CACHE" 2>/dev/null || true
    # Clear any stale per-file diff snapshot and upload-state from a previous
    # task (W1094 — a stale state file would mislead the before_review self-heal
    # into skipping a needed re-upload).
    rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
    rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
  else
    # (W1086) No parseable response and no usable persisted file. A claim always
    # opens a new task window, so unconditionally refresh TASK_BASE_REF to
    # current HEAD and clear the stale per-file snapshot — otherwise a base ref
    # recorded under a previous claim survives and the after_doing diff spans
    # every commit since that older claim. Existing TASK_ identity lines are
    # preserved so a later completion can still recover TASK_ID. Skip silently
    # when HEAD is unresolvable (not a git repo).
    _base_ref=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || true)
    if [ -n "$_base_ref" ]; then
      if [ -f "$ENV_CACHE" ]; then
        # Drop the previous claim's TASK_BASE_REF AND TASK_DIRTY_BASELINE so a
        # stale baseline can't survive into this claim, then re-write both fresh.
        _preserved=$(grep -v -e '^TASK_BASE_REF=' -e '^TASK_DIRTY_BASELINE=' "$ENV_CACHE" 2>/dev/null || true)
        {
          [ -n "$_preserved" ] && printf '%s\n' "$_preserved"
          echo "TASK_BASE_REF='$_base_ref'"
          echo "TASK_DIRTY_BASELINE='$_dirty_baseline_b64'"
        } > "$ENV_CACHE" 2>/dev/null || true
      else
        {
          echo "TASK_BASE_REF='$_base_ref'"
          echo "TASK_DIRTY_BASELINE='$_dirty_baseline_b64'"
        } > "$ENV_CACHE" 2>/dev/null || true
      fi
      rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
      rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
    fi
  fi
fi

# Load cached env vars if available (all hooks benefit from this)
if [ -f "$ENV_CACHE" ]; then
  set -a
  . "$ENV_CACHE" 2>/dev/null || true
  set +a
fi

# --- (W1094) Changed-files upload self-heal ---
# Runs only for before_review (gated internally). On a FRESH timeout budget it
# re-verifies the after_doing upload via .stride-diff-upload-state and
# re-captures + re-PUTs when no healthy 2xx is on record for this task. A
# successful after_doing upload short-circuits (no duplicate PUT). Best-effort:
# never blocks the primary hook.
self_heal_changed_files_upload || true

# --- Execute the primary hook ---
# run_stride_section emits the structured JSON itself (success or failed
# shape) and finalizes the per-file diff snapshot. Failure exits 2 here to
# preserve the existing PreToolUse blocking semantic for after_doing (other
# routes are PostToolUse where exit 2 has no gating effect but matches the
# historical exit shape).
run_stride_section "$HOOK_NAME"
PRIMARY_RC=$?

if [ "$PRIMARY_RC" -ne 0 ]; then
  exit "$PRIMARY_RC"
fi

# --- After-goal routing (W788 / mirrors stride v1.17.1 W504) ---
# When completing the last child of a goal, run the local `## after_goal`
# section as a blocking hook. Detection prefers the handed response when it is
# complete (D118 fast path) and otherwise falls back to a fresh, hook-initiated
# GET /api/tasks/:id/after_goal_status that is immune to harness truncation
# (D119 — the reliability guarantee). route_after_goal keeps the two paths
# mutually exclusive so the section runs at most once. Missing `## after_goal`
# in .stride.md is a clean no-op (back-compat); the server's grace-window worker
# still covers goal completion when neither path can detect it. A non-zero
# section exit is surfaced via the structured JSON shape, never as a non-zero
# script exit (the primary curl already succeeded).
if [ "$PHASE" = "post" ]; then
  case "$COMMAND" in
    */api/tasks/*/complete*|*/api/tasks/*/mark_reviewed*)
      route_after_goal "$(extract_response_payload "$INPUT")"
      ;;
  esac
fi

# Clean up env cache and per-file diff snapshot after the final hook in the
# lifecycle. after_goal piggy-backs on after_review's lifecycle when present,
# so this gate intentionally stays on $HOOK_NAME == "after_review".
if [ "$HOOK_NAME" = "after_review" ]; then
  rm -f "$ENV_CACHE" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
fi

exit 0
