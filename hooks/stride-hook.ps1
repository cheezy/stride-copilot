# stride-hook.ps1 — Bridges GitHub Copilot's PreToolUse/PostToolUse hooks to Stride .stride.md hook execution
#
# PowerShell companion to stride-hook.sh for Windows compatibility.
# Called by GitHub Copilot's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives hook JSON on stdin, determines if the Bash command is a Stride API call,
# and if so, parses and executes the corresponding .stride.md section.
#
# Usage: echo '{"tool_input":{"command":"curl ..."}}' | pwsh stride-hook.ps1 <pre|post>
#
# Exit codes:
#   0 — Success (or not a Stride API call)
#   2 — Hook command failed (blocks the tool call in PreToolUse context)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Arguments and paths ---
$Phase = if ($args.Count -gt 0) { $args[0] } else { '' }
$ProjectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$StrideMd = Join-Path $ProjectDir '.stride.md'
$EnvCache = Join-Path $ProjectDir '.stride-env-cache'
# (D118) Canonical API-response snapshot. When present, after_goal detection,
# env forwarding, and the claim env-cache refresh prefer it over the harness-
# truncatable tool_response.stdout. Best-effort fast path only — the reliability
# guarantee is D119's hook-initiated fresh call.
$ResponseFile = Join-Path $ProjectDir '.stride/.last-api-response.json'

# Exit early if no phase argument or no .stride.md
if (-not $Phase) { exit 0 }
if (-not (Test-Path $StrideMd)) { exit 0 }

# Read GitHub Copilot hook input from stdin
$Input = @($input) -join "`n"
if (-not $Input) { exit 0 }

# --- Extract the Bash command from hook JSON ---
$Command = ''
try {
    $json = $Input | ConvertFrom-Json
    $Command = $json.tool_input.command
} catch {
    # Fallback: simple string extraction for "command" : "value"
    if ($Input -match '"command"\s*:\s*"([^"]*)"') {
        $Command = $Matches[1]
    }
}

if (-not $Command) { exit 0 }

# --- Determine which Stride hook to run ---
# Routing:
#   post + /api/tasks/claim        → before_doing
#   pre  + /api/tasks/:id/complete → after_doing  (blocks completion if it fails)
#   post + /api/tasks/:id/complete → before_review
#   post + /api/tasks/:id/mark_reviewed → after_review

$HookName = ''

switch ($Phase) {
    'post' {
        if ($Command -match '/api/tasks/claim') {
            $HookName = 'before_doing'
        } elseif ($Command -match '/api/tasks/[^/]+/mark_reviewed') {
            $HookName = 'after_review'
        } elseif ($Command -match '/api/tasks/[^/]+/complete') {
            $HookName = 'before_review'
        }
    }
    'pre' {
        if ($Command -match '/api/tasks/[^/]+/complete') {
            $HookName = 'after_doing'
        }
    }
}

# Not a Stride API call — exit cleanly
if (-not $HookName) { exit 0 }

# Compute the claim-time dirty baseline (W1516). Mirror of
# stride-hook.sh:_compute_dirty_baseline: returns base64 of newline-joined
# "<blobsha>`t<path>" lines for every path git currently reports dirty
# (modified/staged/untracked-not-ignored), where the sha is git's content hash
# of the CURRENT file. Only hashes + paths — never file contents. Quoted
# (special-char) paths are skipped (they fall through to being captured). Empty
# string on any failure (git absent, not a repo, clean tree).
function Get-DirtyBaseline {
    param([string]$Dir)
    try {
        $status = & git -C $Dir status --porcelain 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $status) { return '' }
        $lines = @()
        foreach ($entry in @($status)) {
            if ($entry.Length -lt 4) { continue }
            $p = $entry.Substring(3)
            if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }
            if ($p.StartsWith('"')) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $Dir $p) -PathType Leaf)) { continue }
            $sha = & git -C $Dir hash-object $p 2>$null
            if ($LASTEXITCODE -eq 0 -and $sha) { $lines += "$(($sha | Out-String).Trim())`t$p" }
        }
        if ($lines.Count -eq 0) { return '' }
        return [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
    } catch {
        return ''
    }
}

# Decode $env:TASK_DIRTY_BASELINE (base64 of "<sha>`t<path>" lines) into a
# path -> sha hashtable (W1516). Empty hashtable when unset or undecodable.
function Get-ClaimDirtyBaselineMap {
    $map = @{}
    $blB64 = [System.Environment]::GetEnvironmentVariable('TASK_DIRTY_BASELINE', 'Process')
    if (-not $blB64) { return $map }
    try {
        $txt = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($blB64))
        foreach ($line in ($txt -split "`n")) {
            $ti = $line.IndexOf("`t")
            if ($ti -gt 0) { $map[$line.Substring($ti + 1)] = $line.Substring(0, $ti) }
        }
    } catch {
        $map = @{}
    }
    return $map
}

# (D118) Read the canonical API-response snapshot. Returns the parsed object
# when the file exists and holds valid JSON, else $null so callers fall back to
# the tool_response parse. Defined ahead of the claim env-cache block and
# Get-ResponsePayload so both can prefer the file. Best-effort fast path — the
# reliability guarantee is D119's hook-initiated fresh call.
function Read-CanonicalResponse {
    if (-not $ResponseFile) { return $null }
    if (-not (Test-Path -LiteralPath $ResponseFile -PathType Leaf)) { return $null }
    $content = $null
    try { $content = Get-Content -LiteralPath $ResponseFile -Raw -ErrorAction Stop } catch { return $null }
    if (-not $content) { return $null }
    try { return ($content | ConvertFrom-Json) } catch { return $null }
}

# (W1609) Capture THIS call's API response to the canonical file so the file-
# first resolver and the claim env-cache refresh read the CURRENT call's data
# rather than a stale prior-call file. Only complete, valid JSON is written — a
# truncated stdout leaves any out-of-band copy intact so a value written by a
# curl passthrough (or a later phase) survives. Best-effort; never throws.
function Save-CanonicalResponse {
    param([string]$InputJson)
    if (-not $ResponseFile) { return }
    if (-not $InputJson) { return }
    $parsed = $null
    try { $parsed = $InputJson | ConvertFrom-Json } catch { return }
    if ($null -eq $parsed) { return }
    if ($parsed.PSObject.Properties.Name -notcontains 'tool_response') { return }
    $resp = $parsed.tool_response
    if (-not $resp) { return }

    $payloadStr = $null
    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
        $payloadStr = [string]$resp.stdout
    } elseif ($resp -is [string]) {
        $payloadStr = $resp
    } elseif ($resp -is [PSCustomObject]) {
        try { $payloadStr = ($resp | ConvertTo-Json -Depth 100 -Compress) } catch { return }
    }
    if (-not $payloadStr) { return }
    # A truncated blob must never overwrite a good file — only persist valid JSON.
    try { $null = $payloadStr | ConvertFrom-Json } catch { return }

    try {
        $dir = Split-Path -Parent $ResponseFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Set-Content -LiteralPath $ResponseFile -Value $payloadStr -NoNewline -Encoding UTF8
    } catch {
        # Best-effort — an unwritten file just falls back to the stdout parse.
    }
}

# (W1609) Persist THIS call's response to the canonical file before the claim
# env-cache refresh reads it, so a valid current stdout overwrites any stale
# prior-call file (no staleness regression) and a truncated stdout leaves an
# out-of-band copy intact.
if ($Phase -eq 'post') {
    Save-CanonicalResponse -InputJson $Input
}

# --- Environment variable caching ---
# After a successful claim (before_doing), extract task metadata from the API
# response and cache it. All subsequent hooks load the cache so .stride.md
# commands can reference $TASK_IDENTIFIER, $TASK_TITLE, etc.

if ($HookName -eq 'before_doing') {
    try {
        $taskJson = $null

        # (D118/W1609) Fast path — prefer the untruncated canonical response
        # file. Falls through to the tool_response parse below when it is absent
        # or does not carry a task object.
        $canon = Read-CanonicalResponse
        if ($null -ne $canon) {
            $canonProps = $canon.PSObject.Properties.Name
            if (($canonProps -contains 'data') -and $canon.data -and
                ($canon.data.PSObject.Properties.Name -contains 'id') -and $canon.data.id) {
                $taskJson = $canon.data
            } elseif (($canonProps -contains 'id') -and $canon.id) {
                $taskJson = $canon
            }
        }

        $json = $Input | ConvertFrom-Json
        $response = $json.tool_response
        if (-not $taskJson -and $response) {

            # Shape 1: host wraps API JSON inside tool_response.stdout as a string
            if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'stdout') {
                try {
                    $innerObj = $response.stdout | ConvertFrom-Json
                    if ($innerObj.data -and $innerObj.data.id) {
                        $taskJson = $innerObj.data
                    } elseif ($innerObj.id) {
                        $taskJson = $innerObj
                    }
                } catch {
                    # stdout not parseable — fall through
                }
            }

            # Shape 2: tool_response is a JSON-encoded string
            if (-not $taskJson -and $response -is [string]) {
                try {
                    $responseObj = $response | ConvertFrom-Json
                    if ($responseObj.data -and $responseObj.data.id) {
                        $taskJson = $responseObj.data
                    } elseif ($responseObj.id) {
                        $taskJson = $responseObj
                    }
                } catch {
                    # Response not parseable JSON — skip caching
                }
            }

            # Shape 3: tool_response is raw API JSON object. Guard property access
            # by name first — under Set-StrictMode Latest, reading a non-existent
            # property (e.g. .data on the stdout-wrapper object) throws, which
            # would otherwise abort the whole caching block before the
            # persisted-output fallback and base-ref refresh run.
            if (-not $taskJson -and $response -is [PSCustomObject]) {
                $responseProps = $response.PSObject.Properties.Name
                if (($responseProps -contains 'data') -and $response.data -and $response.data.id) {
                    $taskJson = $response.data
                } elseif (($responseProps -contains 'id') -and $response.id) {
                    $taskJson = $response
                }
            }

            # Shape 4: persisted-output file fallback (W1087, mirrors the bash
            # Shape 4). When the claim response is large, Copilot writes the tool
            # output to a file and leaves only a "Full output saved to: <absolute
            # path>" notice in stdout. Recover the API JSON by reading that file.
            # The path is harness-controlled, so require an existing regular file
            # and parse it with ConvertFrom-Json only — never invoke, dot-source,
            # or write to it.
            if (-not $taskJson) {
                $notice = $null
                if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'stdout') {
                    $notice = $response.stdout
                } elseif ($response -is [string]) {
                    $notice = $response
                }
                if ($notice -and ($notice -imatch 'saved to')) {
                    # Keep the path from its first "/" to end of the notice line so
                    # a path containing spaces survives; tolerate a wrapping quote.
                    $noticeLine = ($notice -split "`n" | Where-Object { $_ -imatch 'saved to' } | Select-Object -First 1)
                    if ($noticeLine) {
                        $persistPath = '/' + ($noticeLine -replace '^[^/]*/', '')
                        $persistPath = ($persistPath.TrimEnd()) -replace '"$', ''
                        if (Test-Path -LiteralPath $persistPath -PathType Leaf) {
                            try {
                                $persistObj = (Get-Content -LiteralPath $persistPath -Raw -ErrorAction SilentlyContinue) | ConvertFrom-Json
                                # Guard property access by name (StrictMode) so an
                                # id-only persisted payload caches identity lines
                                # rather than throwing and falling through.
                                $persistProps = $persistObj.PSObject.Properties.Name
                                if (($persistProps -contains 'data') -and $persistObj.data -and $persistObj.data.id) {
                                    $taskJson = $persistObj.data
                                } elseif (($persistProps -contains 'id') -and $persistObj.id) {
                                    $taskJson = $persistObj
                                }
                            } catch {
                                # persisted file not parseable JSON — fall through
                            }
                        }
                    }
                }
            }
        }

        # (W1087/W1609) Compute the claim-time base ref once, OUTSIDE the
        # tool_response block so TASK_BASE_REF refreshes on every claim
        # regardless of whether the task JSON came from the canonical file, the
        # tool_response parse, or nothing at all. A claim always opens a new task
        # window. An empty result (not a git repo / git absent) is tolerated and
        # must never throw — existing non-git env-cache tests rely on this.
        $baseRef = ''
        try {
            $rev = & git -C $ProjectDir rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $rev) { $baseRef = ($rev | Out-String).Trim() }
        } catch {
            $baseRef = ''
        }

        # (W1516) Snapshot the already-dirty paths at claim time, base64 in a
        # single safe env-cache line (many paths, no special-char breakage,
        # only hashes — never file contents). The upload filter subtracts it
        # so unrelated pre-existing edits are not misattributed to the agent.
        $dirtyBaselineB64 = Get-DirtyBaseline -Dir $ProjectDir

        if ($taskJson) {
                $cacheLines = @(
                    "TASK_ID=$($taskJson.id)"
                    "TASK_IDENTIFIER=$($taskJson.identifier)"
                    "TASK_TITLE=$($taskJson.title)"
                    "TASK_STATUS=$($taskJson.status)"
                    "TASK_COMPLEXITY=$($taskJson.complexity)"
                    "TASK_PRIORITY=$($taskJson.priority)"
                    "TASK_BASE_REF=$baseRef"
                    "TASK_DIRTY_BASELINE=$dirtyBaselineB64"
                )
                $cacheLines | Set-Content -Path $EnvCache -Encoding UTF8
                # Clear any stale per-file diff snapshot and upload-state from a
                # previous task (W1094 — a stale state file would mislead the
                # before_review self-heal into skipping a needed re-upload).
                Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
                Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
            } elseif ($baseRef) {
                # (W1086/W1087) No parseable response and no usable persisted file.
                # A claim still opens a new task window, so unconditionally refresh
                # TASK_BASE_REF to current HEAD and clear the stale per-file
                # snapshot — otherwise a base ref recorded under a previous claim
                # survives. Existing TASK_ identity lines are preserved so a later
                # completion can still recover TASK_ID.
                # Drop the previous claim's TASK_BASE_REF AND TASK_DIRTY_BASELINE
                # so a stale baseline cannot survive into this claim, then
                # re-write both fresh.
                $preserved = @()
                if (Test-Path $EnvCache) {
                    $preserved = @(Get-Content $EnvCache -Encoding UTF8 | Where-Object { $_ -notmatch '^TASK_BASE_REF=' -and $_ -notmatch '^TASK_DIRTY_BASELINE=' })
                }
                $newLines = $preserved + "TASK_BASE_REF=$baseRef" + "TASK_DIRTY_BASELINE=$dirtyBaselineB64"
                $newLines | Set-Content -Path $EnvCache -Encoding UTF8
                Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
                Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
            }
    } catch {
        # Caching failure is non-fatal
    }
}

# Load cached env vars if available (all hooks benefit from this)
if (Test-Path $EnvCache) {
    Get-Content $EnvCache -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

# Helper: resolve the Stride API base URL for the changed_files upload.
# Primary source is $ProjectDir/.stride_auth.md (the same file the agent reads)
# — its `**API URL:**` line. Falls back to a literal URL in the intercepted
# $Command for back-compat when the auth file is absent. Mirror of
# stride-hook.sh:resolve_stride_api_url.
function Resolve-StrideApiUrl {
    $url = ''
    $authPath = Join-Path $ProjectDir '.stride_auth.md'
    if (Test-Path $authPath) {
        foreach ($line in (Get-Content -Path $authPath)) {
            if ($line -match '\*\*API URL:\*\*' -and $line -match '(https?://[A-Za-z0-9._:/-]+)') {
                $url = $Matches[1]; break
            }
        }
    }
    if (-not $url -and $Command -match '(https?://[A-Za-z0-9._-]+(:[0-9]+)?)') { $url = $Matches[1] }
    return $url
}

# Helper: resolve the Stride API bearer token for the changed_files upload.
# Primary source is the production `**API Token:**` line in
# $ProjectDir/.stride_auth.md — deliberately NOT the `**Local API Token:**`
# line (the `**API Token:**` pattern does not match `**Local API Token:**`).
# Falls back to a literal `Bearer <token>` in the intercepted $Command. Never
# logs the token. Mirror of stride-hook.sh:resolve_stride_api_token.
function Resolve-StrideApiToken {
    $token = ''
    $authPath = Join-Path $ProjectDir '.stride_auth.md'
    if (Test-Path $authPath) {
        foreach ($line in (Get-Content -Path $authPath)) {
            if ($line -match '\*\*API Token:\*\*' -and $line -match '`([^`]+)`') {
                $token = $Matches[1]; break
            }
        }
    }
    if (-not $token -and $Command -match 'Bearer\s+([A-Za-z0-9._+/=-]+)') { $token = $Matches[1] }
    return $token
}

# PUT the on-disk snapshot to /api/tasks/<id>/changed_files as the
# transport-encoded envelope {"changed_files":{"encoding":"base64",
# "data":"<b64>"}} so an edge request filter does not misread a unified code
# diff as an attack and drop the upload (D61). The raw file bytes are encoded
# directly so the wire body carries no recognizable source text. Returns the
# HTTP status code as a string ('000' on transport failure), warns on stderr
# for non-2xx, and never throws. Mirror of stride-hook.sh's
# upload_changed_files_snapshot (W1094) — shared by Invoke-FinalizeAfterDoing
# and the before_review self-heal. Kept PowerShell 5.1-compatible: rather than
# -SkipHttpErrorCheck (7+ only), a non-2xx WebException is caught and its real
# status code recovered from the exception's Response so the self-heal still
# records the true outcome.
function Invoke-ChangedFilesUpload {
    param([string]$TaskId, [string]$ApiBase, [string]$Token)
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    $httpCode = '000'
    try {
        $bytes = [System.IO.File]::ReadAllBytes($snapshotPath)
        # D67: defensively strip the hook's OWN root artifacts from the snapshot
        # before upload. The bash capture already excludes them, but this ps1
        # may PUT a snapshot produced by an older/unfiltered capture or one that
        # was committed into the repo. Match only the exact repo-root paths — a
        # same-named file in a subdirectory has a path prefix and is kept. Only
        # re-encode when an artifact was actually dropped, so an already-clean
        # snapshot uploads byte-for-byte as before; an unparseable snapshot
        # falls through to the raw bytes unchanged.
        try {
            $entries = @([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
            # (W1516) Alongside the D67 self-artifact exclusion, drop entries
            # that were already dirty at claim time AND whose content is
            # unchanged since — pre-existing, task-untouched edits. A baselined
            # path whose CURRENT git hash differs (the task edited it further) is
            # kept, as is any path absent from the baseline.
            $baselineMap = Get-ClaimDirtyBaselineMap
            $filtered = @($entries | Where-Object {
                $p = $_.path
                if ($p -eq '.stride-diff-upload-state' -or $p -eq '.stride-changed-files.json') { return $false }
                # (W1609) Hard-exclude the whole root .stride/ state directory
                # (orchestrator marker, the .last-api-response.json capture) —
                # mirrors stride-hook.sh's `$0 !~ /^\.stride\//`.
                if ($p -match '^\.stride/') { return $false }
                if ($baselineMap.ContainsKey($p)) {
                    $cur = ''
                    try {
                        $h = & git -C $ProjectDir hash-object $p 2>$null
                        if ($LASTEXITCODE -eq 0 -and $h) { $cur = ($h | Out-String).Trim() }
                    } catch { $cur = '' }
                    if ($cur -ne '' -and $cur -eq $baselineMap[$p]) { return $false }
                }
                return $true
            })
            if ($filtered.Count -ne $entries.Count) {
                # Pipe (not -InputObject) so an array is not double-wrapped into
                # [[...]]; guard the empty case explicitly because piping zero
                # items emits nothing rather than `[]`.
                if ($filtered.Count -eq 0) {
                    $filteredJson = '[]'
                } else {
                    $filteredJson = $filtered | ConvertTo-Json -Depth 10 -Compress -AsArray
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($filteredJson)
            }
        } catch {
            # Snapshot not parseable as the expected array — keep the raw bytes.
        }
        $b64 = [System.Convert]::ToBase64String($bytes)
        $body = @{ changed_files = @{ encoding = 'base64'; data = $b64 } } |
            ConvertTo-Json -Depth 5 -Compress
        $resp = Invoke-WebRequest `
            -Uri "$ApiBase/api/tasks/$TaskId/changed_files" `
            -Method Put `
            -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $Token" } `
            -UseBasicParsing -TimeoutSec 10
        $httpCode = "$([int]$resp.StatusCode)"
    } catch {
        # A non-2xx response throws a WebException carrying the real status
        # code — recover it so the self-heal records the true outcome. A
        # transport failure (no Response: connection refused, DNS, timeout)
        # stays '000', matching the bash twin's `|| printf '000'`.
        $_resp = $null
        try { $_resp = $_.Exception.Response } catch { $_resp = $null }
        if ($_resp -and $_resp.StatusCode) {
            $httpCode = "$([int]$_resp.StatusCode)"
        } else {
            $httpCode = '000'
        }
    }
    # Surface a failed upload instead of dropping it silently. The diff is
    # non-fatal to completion, so we warn rather than abort.
    if ($httpCode -notmatch '^2') {
        [Console]::Error.WriteLine(
            "stride-hook: changed_files upload failed (HTTP $httpCode) for task $TaskId")
    }
    return $httpCode
}

# Record the outcome of a changed_files PUT attempt (W1094) so the
# before_review self-heal can verify it on a fresh timeout budget. Task id
# and HTTP code ONLY — never the URL or bearer token (the file lives
# untracked in the project root alongside the other .stride artifacts).
function Write-DiffUploadState {
    param([string]$TaskId, [string]$HttpCode)
    try {
        Set-Content -Path (Join-Path $ProjectDir '.stride-diff-upload-state') `
            -Value "task_id=$TaskId`nhttp_code=$HttpCode" -Encoding UTF8
    } catch {
        # Best-effort: a failed state write must never block the hook.
    }
}

# (D127) Resolve the authoritative task id for the CURRENT completion from the
# /complete or /mark_reviewed URL in the command, independent of the env cache.
# Mirror of stride-hook.sh's task_id_from_command. Those URLs always carry
# /api/tasks/<id>/<action>, so the changed_files upload targets the task the
# agent is actually completing even when a hidden claim left a STALE TASK_ID in
# the env cache — the confirmed empty-changed_files root cause (G321/D126: the
# diff was PUT to the previous task). Returns '' for the claim path (whose URL
# has no id); callers fall back to the env-cache TASK_ID then.
function Get-TaskIdFromCommand {
    param([string]$CommandText)
    if ($CommandText -match '/api/tasks/([0-9]+)/(?:complete|mark_reviewed)') {
        return $Matches[1]
    }
    return ''
}

# Fire-and-forget upload of the per-file diff snapshot to the Stride server.
# Mirror of stride-hook.sh's finalize_after_doing PUT path. URL and token are
# resolved by Resolve-StrideApiUrl / Resolve-StrideApiToken — preferring
# $ProjectDir/.stride_auth.md so the upload works whether the agent's completion
# curl used literal values or shell variables, with the $Command literal
# extraction kept as a back-compat fallback. Silently no-ops if any prerequisite
# is missing (snapshot file, URL, token, TASK_ID) so behavior degrades to the
# legacy on-disk-only snapshot.
function Invoke-FinalizeAfterDoing {
    if ($HookName -ne 'after_doing') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    if (-not (Test-Path $snapshotPath)) { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken

    # (D127) Target the task id from the /complete URL, not the env cache, so a
    # stale TASK_ID from a hidden claim response cannot route the diff to the
    # wrong task. Fall back to the env-cache TASK_ID only if the URL carries no id.
    $taskId = Get-TaskIdFromCommand -CommandText $Command
    if (-not $taskId) { $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process') }
    if (-not $apiBase -or -not $token -or -not $taskId) { return }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    # (W1094) Record the outcome after EVERY PUT attempt so the before_review
    # self-heal can verify it on a fresh timeout budget. A skipped PUT (missing
    # preconditions) deliberately writes nothing: missing state means "no
    # healthy upload on record" and the retry re-checks the same preconditions.
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode
}

# (W1094) Self-heal for the changed_files upload — mirror of stride-hook.sh's
# self_heal_changed_files_upload. The after_doing gate can burn the whole hook
# budget, killing the process before or during the snapshot PUT — or the PUT
# itself returned non-2xx. before_review (PostToolUse on the same completion
# curl) runs on a FRESH budget, so it verifies the recorded outcome and re-PUTs
# the on-disk snapshot when no healthy upload is on record for the current task.
# Best-effort: never throws, never changes the hook's exit semantics. Like the
# bash twin's before_review path the on-disk snapshot is the source of truth, so
# the retry re-uploads it as-is.
function Invoke-SelfHealChangedFilesUpload {
    if ($HookName -ne 'before_review') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    if (-not (Test-Path $snapshotPath)) { return }
    # (D127) Prefer the task id from the /complete URL over the env-cache TASK_ID
    # so the self-heal re-PUTs to the CORRECT task even after a stale claim.
    $taskId = Get-TaskIdFromCommand -CommandText $Command
    if (-not $taskId) { $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process') }
    if (-not $taskId) { return }

    # Healthy 2xx recorded for THIS task → do not re-upload (snapshot semantics
    # anchor at after_doing time; avoid pointless API load). Missing file,
    # different task id, or non-2xx/empty code → retry.
    $stateFile = Join-Path $ProjectDir '.stride-diff-upload-state'
    $stateTask = ''
    $stateCode = ''
    if (Test-Path $stateFile) {
        try {
            foreach ($line in Get-Content -Path $stateFile -Encoding UTF8) {
                if ($line -match '^task_id=(.*)$' -and -not $stateTask) { $stateTask = $Matches[1] }
                if ($line -match '^http_code=(.*)$' -and -not $stateCode) { $stateCode = $Matches[1] }
            }
        } catch {
            # Unreadable state degrades to "retry".
        }
    }
    if ($stateTask -eq $taskId -and $stateCode -match '^2') { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken
    if (-not $apiBase -or -not $token) { return }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode
}

# Per-hook timeout budget in seconds (W1513), keyed on the section name. Mirror
# of stride-hook.sh:_hook_timeout_secs: after_doing = 120; before_doing /
# before_review / after_review / after_goal (and any unrecognized section) = 60.
# Every inner limit sits well under the 300s outer host budget in hooks.json. A
# positive-integer $env:STRIDE_HOOK_TIMEOUT_SECS overrides the budget for every
# section (used by the suites to exercise the timeout path without waiting out
# the real limits, and as an advanced-tuning knob); unset/non-numeric is ignored.
function Get-HookTimeoutSecs {
    param([string]$Section)
    $override = $env:STRIDE_HOOK_TIMEOUT_SECS
    if ($override -match '^[0-9]+$' -and [int]$override -gt 0) {
        return [int]$override
    }
    switch ($Section) {
        'after_doing' { return 120 }
        default       { return 60 }
    }
}

# True when a line ends with a shell line-continuation backslash (W1515).
# Mirror of stride-hook.sh:_has_line_continuation: a trailing backslash
# continues onto the next line only when unescaped — the run of trailing
# backslashes has ODD length. An even run is a literal backslash and does not
# continue. Trailing whitespace is significant (a backslash + space does not
# continue); leading whitespace was already trimmed by the caller.
function Test-LineContinuation {
    param([string]$Line)
    $n = 0
    $i = $Line.Length - 1
    while ($i -ge 0 -and $Line[$i] -eq '\') { $n++; $i-- }
    return (($n % 2) -eq 1)
}

# --- Parse and execute one .stride.md hook section ---
# Mirror of stride-hook.sh:run_stride_section. Takes a section name and:
#   1. Parses the first `## <section>` ```bash``` block from .stride.md.
#   2. Returns 0 immediately when the section is missing or the body is empty
#      (back-compat no-op).
#   3. Otherwise executes each command via `Start-Process bash -c …`; on first
#      failure emits structured failed-JSON and returns 2.
#   4. On all-success emits structured success-JSON and returns 0.
#
# CRITICAL: JSON is routed via [Console]::Out.WriteLine, not via the function
# output pipeline. PowerShell collects pipeline output as the function's
# return value, so `$obj | ConvertTo-Json` inside would pollute the caller's
# `$rc = Invoke-StrideSection ...` assignment with the JSON string alongside
# the int return, breaking the `-ne 0` gate.
function Invoke-StrideSection {
    param([string]$Section)

    $rawContent = Get-Content $StrideMd -Raw -Encoding UTF8
    $rawContent = $rawContent -replace "`r`n", "`n"
    $sectionLines = $rawContent -split "`n"

    $secCommands = ''
    $secFound = $false
    $secCapture = $false

    foreach ($rawLine in $sectionLines) {
        $line = $rawLine.TrimEnd("`r")

        if ($line -match '^## (.+)$') {
            if ($secFound) { break }
            $heading = $Matches[1].TrimEnd()
            if ($heading -eq $Section) { $secFound = $true }
            continue
        }

        if ($secFound) {
            if ($line -match '^```bash') {
                $secCapture = $true
                continue
            }
            if ($line -match '^```') {
                if ($secCapture) { break }
                continue
            }
            if ($secCapture) {
                $secCommands += $line + "`n"
            }
        }
    }

    if (-not $secCommands.Trim()) {
        Invoke-FinalizeAfterDoing
        return 0
    }

    # Build the command list, joining backslash line-continuations (W1515) so a
    # multi-line command runs as ONE command. Blank/comment skipping applies
    # only when starting a fresh command ($secPending empty); a line pulled in
    # by a continuation is appended verbatim. Non-continued input reduces to the
    # pre-W1515 behavior, so single-line commands parse identically.
    $secCmdList = @()
    $secPending = ''
    foreach ($cmd in ($secCommands -split "`n")) {
        $trimmedCmd = $cmd.TrimStart()
        if ($secPending -ne '') {
            $trimmedCmd = $secPending + $trimmedCmd
            $secPending = ''
        } else {
            if (-not $trimmedCmd) { continue }
            if ($trimmedCmd.StartsWith('#')) { continue }
        }
        if (Test-LineContinuation $trimmedCmd) {
            # Drop the single continuation backslash; hold the rest for the next
            # line (literal backslashes preceding it are preserved).
            $secPending = $trimmedCmd.Substring(0, $trimmedCmd.Length - 1)
            continue
        }
        $secCmdList += $trimmedCmd
    }
    # Flush a dangling continuation (final fenced line ended with a backslash).
    if ($secPending -ne '') { $secCmdList += $secPending }

    if ($secCmdList.Count -eq 0) {
        Invoke-FinalizeAfterDoing
        return 0
    }

    Set-Location $ProjectDir

    # Early per-file diff snapshot (W1093) — capture and upload BEFORE the gate
    # commands run, so a slow or failing after_doing gate can't kill the process
    # before the diff upload completes. Invoke-FinalizeAfterDoing gates
    # internally on the GLOBAL $HookName, so this is inert for after_goal (and
    # every non-after_doing hook). The post-loop call below stays as a refresh
    # that picks up any files the gate commands themselves changed.
    Invoke-FinalizeAfterDoing

    $secCompletedCmds = @()
    # Parallel to $secCompletedCmds: one object per successful command holding
    # its tail-truncated stdout/stderr, folded into the success JSON's
    # commands_output array (D65). Keeps passing-gate output off stderr so it is
    # not rendered under a false hook-error label.
    $secCmdOutputs = @()
    # $secStartTime (whole seconds) drives the W1513 per-hook timeout elapsed
    # math; $secStopwatch (W1514) drives the millisecond duration_ms reported in
    # the success JSON — independent clocks so timeout budgeting keeps its cheap
    # second granularity while telemetry gains real sub-second fidelity.
    $secStartTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $secStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # Per-hook timeout budget (W1513): the whole section shares $secHookLimit
    # seconds; each command waits only for the time REMAINING so the section
    # total can never exceed the limit (nor the 300s host ceiling).
    $secHookLimit = Get-HookTimeoutSecs $Section
    $secCmdIndex = 0
    $secCmdTotal = $secCmdList.Count

    foreach ($execTrimmed in $secCmdList) {
        $secStdoutFile = [System.IO.Path]::GetTempFileName()
        $secStderrFile = [System.IO.Path]::GetTempFileName()

        try {
            # ProcessStartInfo.ArgumentList passes each element as an exact
            # argv entry on every platform. Start-Process -ArgumentList must
            # NOT be used here: it joins the elements into a single string,
            # which .NET on Unix re-splits on whitespace, so a multi-word
            # command reaches bash -c mangled and its output is lost.
            $secPsi = [System.Diagnostics.ProcessStartInfo]::new()
            $secPsi.FileName = 'bash'
            $secPsi.ArgumentList.Add('-c')
            $secPsi.ArgumentList.Add($execTrimmed)
            $secPsi.RedirectStandardOutput = $true
            $secPsi.RedirectStandardError = $true
            $secPsi.UseShellExecute = $false
            $secPsi.WorkingDirectory = (Get-Location).Path
            $proc = [System.Diagnostics.Process]::Start($secPsi)
            # Drain both pipes concurrently: a synchronous ReadToEnd on stdout
            # would deadlock if the child fills the stderr pipe buffer (~64KB)
            # while its stdout is still open — gate commands like `mix compile`
            # can emit that much warning text.
            $secOutTask = $proc.StandardOutput.ReadToEndAsync()
            $secErrTask = $proc.StandardError.ReadToEndAsync()

            # Enforce the per-hook budget (W1513). Each command waits only for
            # the time REMAINING in the section budget. Unlike bash — which needs
            # an external timeout/gtimeout and degrades to no enforcement when
            # neither exists — .NET's WaitForExit(ms) is always available, so
            # PowerShell always enforces. On expiry the child (and its tree) is
            # killed and the command is treated as a genuine failure with exit
            # code 124, matching the bash twin and preserving the after_doing
            # exit-2 block (a timeout is a failure, not a silent pass).
            $secElapsed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $secStartTime
            $secRemainingMs = [int]([math]::Max(1, ($secHookLimit - $secElapsed))) * 1000
            $secTimedOut = $false
            if ($proc.WaitForExit($secRemainingMs)) {
                # Second argless WaitForExit ensures the async stdout/stderr
                # reads are fully flushed before we read their .Result.
                $proc.WaitForExit()
            } else {
                $secTimedOut = $true
                try { $proc.Kill($true) } catch { try { $proc.Kill() } catch { } }
                try { $proc.WaitForExit() } catch { }
            }
            Set-Content -Path $secStdoutFile -Value $secOutTask.Result -Encoding UTF8 -NoNewline
            Set-Content -Path $secStderrFile -Value $secErrTask.Result -Encoding UTF8 -NoNewline
            # Make a budget timeout self-describing (mirror of the bash twin's
            # exit-124 annotation) so the failed-JSON and fd2 message name the
            # cause; the synthesized exit code stays 124 for the diagnostician.
            if ($secTimedOut) {
                Add-Content -Path $secStderrFile -Encoding UTF8 `
                    -Value "stride-hook: $Section hook command exceeded its ${secHookLimit}s per-hook timeout budget"
            }

            $secCmdCode = if ($secTimedOut) { 124 } else { $proc.ExitCode }
            if ($secCmdCode -eq 0) {
                $secCompletedCmds += $execTrimmed
                # Do NOT write the passing command's output to stderr (D65):
                # Claude Code renders any hook stderr under a red error label
                # even on exit 0. Capture a tail-truncated copy — same 50-line
                # cap as the failure path — into $secCmdOutputs, folded into the
                # success JSON's commands_output array so agents keep visibility.
                $secOkStdout = ''
                $secOkStderr = ''
                if (Test-Path $secStdoutFile) {
                    # @() guards against $null (empty file) under StrictMode.
                    $allLines = @(Get-Content $secStdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secOkStdout = $allLines -join "`n"
                }
                if (Test-Path $secStderrFile) {
                    $allLines = @(Get-Content $secStderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secOkStderr = $allLines -join "`n"
                }
                $secCmdOutputs += [ordered]@{
                    command = $execTrimmed
                    stdout  = $secOkStdout
                    stderr  = $secOkStderr
                }
            } else {
                $secCmdExit = $secCmdCode
                $secCmdStdout = ''
                $secCmdStderr = ''
                if (Test-Path $secStdoutFile) {
                    # @() coerces $null (empty file) into an empty array so
                    # .Count is safe under Set-StrictMode -Version Latest.
                    $allLines = @(Get-Content $secStdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secCmdStdout = $allLines -join "`n"
                }
                if (Test-Path $secStderrFile) {
                    $allLines = @(Get-Content $secStderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secCmdStderr = $allLines -join "`n"
                }
                Remove-Item -Force $secStdoutFile, $secStderrFile -ErrorAction SilentlyContinue

                $secRemainingCmds = @()
                if (($secCmdIndex + 1) -lt $secCmdTotal) {
                    $secRemainingCmds = $secCmdList[($secCmdIndex + 1)..($secCmdTotal - 1)]
                }

                $failureResult = [ordered]@{
                    hook              = $Section
                    status            = 'failed'
                    failed_command    = $execTrimmed
                    command_index     = $secCmdIndex
                    exit_code         = $secCmdExit
                    stdout            = $secCmdStdout
                    stderr            = $secCmdStderr
                    commands_completed = $secCompletedCmds
                    commands_remaining = $secRemainingCmds
                }
                [Console]::Out.WriteLine(($failureResult | ConvertTo-Json -Depth 5 -Compress))

                [Console]::Error.WriteLine("Stride $Section hook failed on command $($secCmdIndex + 1)/$($secCmdTotal): $execTrimmed")
                if ($secCmdStderr) { [Console]::Error.WriteLine($secCmdStderr) }

                return 2
            }
        } finally {
            Remove-Item -Force $secStdoutFile, $secStderrFile -ErrorAction SilentlyContinue
        }

        $secCmdIndex++
    }

    # Per-file diff snapshot refresh (early call added in W1093) — re-capture
    # after the gate commands succeeded so files they changed are included.
    # No-op outside after_doing (gates on the GLOBAL $HookName, so calling this
    # for "after_goal" does not retrigger).
    Invoke-FinalizeAfterDoing

    $secStopwatch.Stop()
    $secDurationMs = [int]$secStopwatch.Elapsed.TotalMilliseconds

    $successResult = [ordered]@{
        hook               = $Section
        status             = 'success'
        commands_completed = $secCompletedCmds
        commands_output    = @($secCmdOutputs)
        duration_ms        = $secDurationMs
    }
    [Console]::Out.WriteLine(($successResult | ConvertTo-Json -Depth 5 -Compress))

    return 0
}

# (D118/W1609) The single shared response resolver. Source order:
#   1. the canonical response file (survives harness truncation) — D118
#   2. Shape 1 tool_response.stdout wrap (Copilot Bash tool) — a TRUNCATED stdout
#      fails to parse and MUST resolve to $null (not the wrapper) so the D119
#      fresh call fires, hence elseif never a fall-through to the raw-object shape
#   3. Shape 2 tool_response is itself a JSON-encoded string
#   4. Shape 3 raw API JSON object directly (other harnesses)
#   5. Shape 4 W1086 persisted-output file named by a "Full output saved to:
#      <path>" stdout notice, when stdout was too large to inline
# Returns the parsed payload object, or $null. Reused by Test-AfterGoalInResponse,
# Set-AfterGoalEnv (env forwarding), AND the after_goal routing so none of them
# can diverge. Mirrors stride-hook.sh:extract_response_payload.
function Get-ResponsePayload {
    param([string]$InputJson)

    # (D118) Fast path — prefer the untruncated canonical response file.
    $fromFile = Read-CanonicalResponse
    if ($null -ne $fromFile) { return $fromFile }

    if (-not $InputJson) { return $null }

    try {
        $parsed = $InputJson | ConvertFrom-Json
    } catch {
        return $null
    }

    if ($parsed.PSObject.Properties.Name -notcontains 'tool_response') { return $null }
    $resp = $parsed.tool_response
    if (-not $resp) { return $null }

    $payload = $null

    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
        # Shape 1: {"stdout":"<json>"} wrap. A truncated stdout fails to parse and
        # MUST resolve to $null so the D119 fresh call fires — hence elseif, never
        # a fall-through to the raw-object shape below.
        try { $payload = $resp.stdout | ConvertFrom-Json } catch { $payload = $null }
    } elseif ($resp -is [string]) {
        # Shape 2: tool_response is itself a JSON-encoded string.
        try { $payload = $resp | ConvertFrom-Json } catch { $payload = $null }
    } elseif ($resp -is [PSCustomObject]) {
        # Shape 3: raw API JSON object directly (other harnesses).
        $payload = $resp
    }

    # (W1086) Shape 4: persisted-output file fallback. When the response is
    # large, Copilot writes the tool output to a file and leaves only a
    # "Full output saved to: <path>" notice in stdout. Recover the API JSON by
    # reading that file — an existing regular file parsed with ConvertFrom-Json
    # only; never invoked, dot-sourced, or written.
    if ($null -eq $payload) {
        $notice = $null
        if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
            $notice = [string]$resp.stdout
        } elseif ($resp -is [string]) {
            $notice = $resp
        }
        if ($notice -and ($notice -imatch 'saved to')) {
            $noticeLine = ($notice -split "`n" | Where-Object { $_ -imatch 'saved to' } | Select-Object -First 1)
            if ($noticeLine) {
                $persistPath = '/' + ($noticeLine -replace '^[^/]*/', '')
                $persistPath = ($persistPath.TrimEnd()) -replace '"$', ''
                if (Test-Path -LiteralPath $persistPath -PathType Leaf) {
                    try {
                        $payload = (Get-Content -LiteralPath $persistPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json)
                    } catch {
                        $payload = $null
                    }
                }
            }
        }
    }

    return $payload
}

# Pure predicate on an ALREADY-resolved payload object: does it carry an
# after_goal hook entry? Single-sourced so Test-AfterGoalInResponse and
# Invoke-AfterGoalRouting share one detection (mirrors bash payload_has_after_goal).
function Test-PayloadHasAfterGoal {
    param($Payload)

    if ($null -eq $Payload) { return $false }
    if (-not ($Payload.PSObject.Properties.Name -contains 'hooks')) { return $false }
    if ($null -eq $Payload.hooks) { return $false }

    foreach ($entry in @($Payload.hooks)) {
        if ($entry -and ($entry.PSObject.Properties.Name -contains 'name') -and $entry.name -eq 'after_goal') {
            return $true
        }
    }

    return $false
}

# Detect an `after_goal` entry in the response. (D118) The payload shapes and the
# canonical-file fast path live in Get-ResponsePayload now — detection and env
# extraction must agree. ConvertFrom-Json is always available in PowerShell so
# no $HAS_JQ-style gate is needed.
function Test-AfterGoalInResponse {
    param([string]$InputJson)

    Test-PayloadHasAfterGoal -Payload (Get-ResponsePayload -InputJson $InputJson)
}

# Export the server-supplied `env` object from an ALREADY-RESOLVED response
# payload's after_goal hook entry (W1512). Mirror of
# stride-hook.sh:export_after_goal_env. The stride-workflow SKILL promises
# GOAL_ID/GOAL_IDENTIFIER/GOAL_TITLE/GOAL_DESCRIPTION (plus BOARD_*/COLUMN_*/
# AGENT_NAME when present) reach the after_goal child process. This selects the
# FIRST after_goal hook entry's `env` object and sets each key VERBATIM into the
# process environment so the subsequent Invoke-StrideSection 'after_goal' (which
# runs the section via `bash -c`, inheriting the process env) sees them.
#
# (D119) Takes a resolved payload object — NOT a hook input — so the D118 fast
# path and the D119 fresh-call path can both feed Invoke-AfterGoalSection a
# payload they already resolved (the fast path via Get-ResponsePayload, the fresh
# call via the synthetic after_goal-entry wrapper it builds from the endpoint env).
#
# Contract: values are copied verbatim; NEVER invented, derived, or looked up
# client-side. A missing env object (or missing keys) is a clean no-op.
function Set-AfterGoalEnv {
    param($Payload)

    if ($null -eq $Payload) { return }
    if (-not ($Payload.PSObject.Properties.Name -contains 'hooks')) { return }
    if ($null -eq $Payload.hooks) { return }

    $agEntry = $null
    foreach ($entry in @($Payload.hooks)) {
        if ($entry -and ($entry.PSObject.Properties.Name -contains 'name') -and $entry.name -eq 'after_goal') {
            $agEntry = $entry
            break
        }
    }
    if ($null -eq $agEntry) { return }

    $agEnv = $null
    if ($agEntry.PSObject.Properties.Name -contains 'env') { $agEnv = $agEntry.env }

    if ($null -ne $agEnv -and ($agEnv -is [PSCustomObject])) {
        foreach ($prop in $agEnv.PSObject.Properties) {
            $val = if ($null -eq $prop.Value) { '' } else { [string]$prop.Value }
            [System.Environment]::SetEnvironmentVariable($prop.Name, $val, 'Process')
            # (W1612) Persist to the env cache so the agent's SEPARATE follow-up
            # PATCH /api/tasks/:goal_id/after_goal process (which does NOT inherit
            # this hook's process env) can read GOAL_* too.
            Add-Content -Path $EnvCache -Value ("{0}={1}" -f $prop.Name, $val) -Encoding UTF8
        }
    }

    # (W1612) Parent-id fallback: the server may build the after_goal env from
    # the completed child task and OMIT GOAL_ID (or send it empty). The parent
    # id in the same response's data object IS the goal id — without it the
    # ## after_goal section (and the follow-up PATCH) has no target.
    $goalId = [System.Environment]::GetEnvironmentVariable('GOAL_ID', 'Process')
    if (-not $goalId) {
        $parentId = $null
        $payloadProps = $Payload.PSObject.Properties.Name
        if (($payloadProps -contains 'data') -and $Payload.data -and
            ($Payload.data.PSObject.Properties.Name -contains 'parent_id')) {
            $parentId = $Payload.data.parent_id
        } elseif ($payloadProps -contains 'parent_id') {
            $parentId = $Payload.parent_id
        }
        if ($null -ne $parentId -and "$parentId") {
            [System.Environment]::SetEnvironmentVariable('GOAL_ID', "$parentId", 'Process')
            Add-Content -Path $EnvCache -Value ("GOAL_ID={0}" -f "$parentId") -Encoding UTF8
        }
    }
}

# --- After-goal execution (shared by the D118 fast path and the D119 fresh call) ---
# (D119) Export GOAL_* from the given ALREADY-RESOLVED payload and run the local
# ## after_goal section as a blocking hook, restoring HOOK_NAME afterward.
# Centralised so both detection paths run the section identically — and, because
# Invoke-AfterGoalRouting calls exactly one path, exactly once (de-dup). Mirrors
# bash run_after_goal_section.
function Invoke-AfterGoalSection {
    param($Payload)
    Set-AfterGoalEnv -Payload $Payload
    $savedHookNameEnv = [System.Environment]::GetEnvironmentVariable('HOOK_NAME', 'Process')
    [System.Environment]::SetEnvironmentVariable('HOOK_NAME', 'after_goal', 'Process')
    $null = Invoke-StrideSection -Section 'after_goal'
    [System.Environment]::SetEnvironmentVariable('HOOK_NAME', $savedHookNameEnv, 'Process')
}

# (D119) Reliability guarantee. Detect after_goal via a fresh, hook-initiated
# GET /api/tasks/:id/after_goal_status (kanban W1613's compact endpoint). An HTTP
# call the hook makes itself is NOT subject to the Bash-tool output truncation
# that can gut the agent-handed /complete response, and needs zero agent
# cooperation. Runs ## after_goal from the endpoint's compact GOAL_* env when
# after_goal_armed is true. Best-effort: a missing prerequisite (TASK_ID/URL/
# token) or an unreachable / non-JSON endpoint degrades to a clean no-op — the
# server's grace-window worker still completes the goal. Never logs the token.
function Invoke-AfterGoalDetectionViaApi {
    $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process')
    if (-not $taskId) { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken
    if (-not $apiBase -or -not $token) { return }

    $resp = $null
    try {
        $resp = Invoke-WebRequest `
            -Uri "$apiBase/api/tasks/$taskId/after_goal_status" `
            -Method Get `
            -Headers @{ Authorization = "Bearer $token" } `
            -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 10
    } catch {
        return
    }
    if ($null -eq $resp) { return }

    $status = $null
    try { $status = $resp.Content | ConvertFrom-Json } catch { return }
    if ($null -eq $status) { return }

    $armed = $false
    if (($status.PSObject.Properties.Name -contains 'after_goal_armed') -and $status.after_goal_armed) {
        $armed = $true
    }
    if (-not $armed) { return }

    # Wrap the endpoint's flat env into the after_goal-hook-entry shape
    # Set-AfterGoalEnv consumes; carry goal_id as data.parent_id so a GOAL_ID
    # parent-id fallback still applies if the env omits it.
    $envObj = if ($status.PSObject.Properties.Name -contains 'env') { $status.env } else { [PSCustomObject]@{} }
    $goalId = if ($status.PSObject.Properties.Name -contains 'goal_id') { $status.goal_id } else { $null }
    $payload = [PSCustomObject]@{
        hooks = @([PSCustomObject]@{ name = 'after_goal'; env = $envObj })
        data  = [PSCustomObject]@{ parent_id = $goalId }
    }

    Invoke-AfterGoalSection -Payload $payload
}

# --- After-goal routing (W789 / D118 / D119) ---
# Two mutually-exclusive paths so ## after_goal runs at most once:
#   * Fast path (D118): a resolved (complete) payload answers definitively —
#     armed runs the section; parseable-but-absent means definitively not armed.
#   * Reliability guarantee (D119): a $null payload (truncated/absent/unparseable
#     handed response) triggers the hook-initiated fresh call.
function Invoke-AfterGoalRouting {
    param($Payload)

    if ($null -ne $Payload) {
        if (Test-PayloadHasAfterGoal -Payload $Payload) { Invoke-AfterGoalSection -Payload $Payload }
        return
    }

    Invoke-AfterGoalDetectionViaApi
}

# --- (W1094) Changed-files upload self-heal ---
# Runs only for before_review (gated internally). On a FRESH timeout budget it
# re-verifies the after_doing upload via .stride-diff-upload-state and re-PUTs
# the on-disk snapshot when no healthy 2xx is on record for this task. A
# successful after_doing upload short-circuits (no duplicate PUT). Best-effort:
# never blocks the primary hook.
Invoke-SelfHealChangedFilesUpload

# --- Execute the primary hook ---
$primaryRc = Invoke-StrideSection -Section $HookName

if ($primaryRc -ne 0) {
    exit $primaryRc
}

# --- After-goal routing (W789 / mirrors stride-hook.sh W504 / D118 / D119) ---
# When completing the last child of a goal, run the local `## after_goal`
# section as a blocking hook. Detection prefers the handed response when it is
# complete (D118 fast path via the file-first Get-ResponsePayload) and otherwise
# falls back to a fresh, hook-initiated GET /api/tasks/:id/after_goal_status that
# is immune to harness truncation (D119 — the reliability guarantee).
# Invoke-AfterGoalRouting keeps the two paths mutually exclusive so the section
# runs at most once. Missing `## after_goal` is a clean no-op; the server's
# grace-window worker still covers goal completion when neither path can detect
# it. A non-zero section exit is surfaced via the structured JSON shape (emitted
# by the function), never as a non-zero script exit (the primary curl succeeded).
if ($Phase -eq 'post' -and ($Command -match '/api/tasks/[^/]+/(complete|mark_reviewed)')) {
    Invoke-AfterGoalRouting -Payload (Get-ResponsePayload -InputJson $Input)
}

# Clean up per-lifecycle state after the final hook. after_goal piggy-backs on
# after_review when present, so this gate intentionally stays on $HookName ==
# 'after_review'. Mirrors stride-hook.sh, which removes both the env cache and
# the changed-files snapshot here.
if ($HookName -eq 'after_review') {
    Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
}

exit 0
