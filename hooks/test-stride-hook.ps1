# test-stride-hook.ps1 — Tests for stride-hook.ps1 PowerShell hook script
#
# Mirrors all 6 test groups from test-stride-hook.sh.
# Self-contained — no Pester or external dependencies.
#
# Usage: pwsh test-stride-hook.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PASS = 0
$script:FAIL = 0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookScript = Join-Path $ScriptDir 'stride-hook.ps1'

# --- Assertion helpers ---

function Assert-Eq {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected: $($Expected.Substring(0, [Math]::Min(200, $Expected.Length)))"
        Write-Host "    actual:   $($Actual.Substring(0, [Math]::Min(200, $Actual.Length)))"
        $script:FAIL++
    }
}

function Assert-Contains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected to contain: $Needle"
        Write-Host "    actual: $($Haystack.Substring(0, [Math]::Min(200, $Haystack.Length)))"
        $script:FAIL++
    }
}

function Assert-NotContains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if (-not $Haystack.Contains($Needle)) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected NOT to contain: $Needle"
        $script:FAIL++
    }
}

function Assert-Exit {
    param([string]$Label, [int]$Expected, [int]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $Label (exit $Actual)" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected exit: $Expected"
        Write-Host "    actual exit:   $Actual"
        $script:FAIL++
    }
}

# --- Helper: run stride-hook.ps1 with input and capture output ---
function Invoke-HookScript {
    param(
        [string]$InputJson,
        [string]$Phase,
        [string]$ProjectDir
    )
    $tempInput = [System.IO.Path]::GetTempFileName()
    $tempOutput = [System.IO.Path]::GetTempFileName()
    $tempError = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tempInput -Value $InputJson -Encoding UTF8 -NoNewline
        $envArgs = @{}
        if ($ProjectDir) {
            $envArgs['CLAUDE_PROJECT_DIR'] = $ProjectDir
        }
        # Build environment block
        $envBlock = [System.Collections.Generic.Dictionary[string,string]]::new()
        foreach ($key in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
            $envBlock[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
        }
        if ($ProjectDir) {
            $envBlock['CLAUDE_PROJECT_DIR'] = $ProjectDir
        }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh'
        $psi.Arguments = "-NoProfile -File `"$HookScript`" $Phase"
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($kv in $envBlock.GetEnumerator()) {
            $psi.Environment[$kv.Key] = $kv.Value
        }
        if ($ProjectDir) {
            $psi.Environment['CLAUDE_PROJECT_DIR'] = $ProjectDir
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($InputJson)
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        return @{
            ExitCode = $proc.ExitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    } finally {
        Remove-Item -Force $tempInput, $tempOutput, $tempError -ErrorAction SilentlyContinue
    }
}

# --- Helper: wait for a listener job to accept connections ---
# Start-Job spawns a whole pwsh process, so the HttpListener inside it can take
# longer to come up than the hook subprocess takes to fire its PUT. Poll the
# port until it accepts a TCP connection (or the timeout elapses) before
# invoking the hook, otherwise the PUT races the listener startup.
function Wait-ForListener {
    param([int]$Port, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $client.Connect('localhost', $Port)
            if ($client.Connected) { return $true }
        } catch {
            Start-Sleep -Milliseconds 100
        } finally {
            $client.Dispose()
        }
    }
    return $false
}

# ============================================================
# Setup: create temp directory with test fixtures
# ============================================================
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "stride-ps-test-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {

# --- Test .stride.md files ---

Set-Content -Path (Join-Path $TmpDir 'basic.stride.md') -Value @'
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
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'with-comments.stride.md') -Value @'
## before_doing
```bash
# This is a comment
echo "step one"
   echo "indented step"
echo "step three"
# Another comment
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'no-hook.stride.md') -Value @'
## before_doing
```bash
echo "only before_doing here"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'empty-block.stride.md') -Value @'
## after_doing
```bash
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'multiple-code-blocks.stride.md') -Value @'
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
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'no-bash-block.stride.md') -Value @'
## before_doing

Just some text, no code block.

## after_doing
```bash
echo "after_doing works"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'adjacent-sections.stride.md') -Value @'
## before_doing
```bash
echo "before"
```
## after_doing
```bash
echo "after"
```
'@ -Encoding UTF8

# ============================================================
# Test Group 1: JSON command extraction
# ============================================================
Write-Host ""
Write-Host "=== Test Group 1: JSON command extraction ==="

# We test extraction by providing JSON and checking if the script
# routes correctly (which proves the command was extracted).
# For isolated extraction tests, we check that non-Stride commands
# produce no output and exit 0.

$proj = Join-Path $TmpDir 'g1-project'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
Copy-Item (Join-Path $TmpDir 'basic.stride.md') (Join-Path $proj '.stride.md')

# 1a: Standard claim command extracts correctly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "standard claim URL exits 0" 0 $r.ExitCode
Assert-Contains "claim runs before_doing" "pulling latest" $r.Stdout

# 1b: Complete command extracts correctly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete"}}' -Phase 'pre' -ProjectDir $proj
Assert-Exit "complete URL exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "running tests" $r.Stdout

# 1c: No command key present
$r = Invoke-HookScript -InputJson '{"tool_input":{"other_key":"some value"}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "no command key exits 0" 0 $r.ExitCode

# 1d: Empty command value
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":""}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "empty command exits 0" 0 $r.ExitCode

# 1e: Completely unrelated JSON
$r = Invoke-HookScript -InputJson '{"foo":"bar","baz":42}' -Phase 'post' -ProjectDir $proj
Assert-Exit "unrelated JSON exits 0" 0 $r.ExitCode

# ============================================================
# Test Group 2: .stride.md section parser
# ============================================================
Write-Host ""
Write-Host "=== Test Group 2: .stride.md section parser ==="

$proj2 = Join-Path $TmpDir 'g2-project'
New-Item -ItemType Directory -Path $proj2 -Force | Out-Null

$ClaimJson = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}'
$CompleteJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'
$ReviewJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}'

# 2a-d: Parse all 4 sections from basic file
Copy-Item (Join-Path $TmpDir 'basic.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: before_doing line 1" 'pulling latest' $r.Stdout
Assert-Contains "basic: before_doing line 2" 'getting deps' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "basic: after_doing line 1" 'running tests' $r.Stdout
Assert-Contains "basic: after_doing line 2" 'running credo' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: before_review" 'creating pr' $r.Stdout

$r = Invoke-HookScript -InputJson $ReviewJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: after_review" 'deploying' $r.Stdout

# 2e: Sections don't bleed
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-NotContains "sections do not bleed" 'running tests' $r.Stdout

# 2f: Hook not present in file
Copy-Item (Join-Path $TmpDir 'no-hook.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Exit "missing hook exits 0" 0 $r.ExitCode

# 2g: Empty code block
Copy-Item (Join-Path $TmpDir 'empty-block.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Exit "empty code block exits 0" 0 $r.ExitCode

# 2h: Only first code block captured
Copy-Item (Join-Path $TmpDir 'multiple-code-blocks.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "first block captured" 'first command' $r.Stdout
Assert-NotContains "second block ignored" 'should not appear' $r.Stdout

# 2i: Section with no bash block
Copy-Item (Join-Path $TmpDir 'no-bash-block.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Exit "no bash block exits 0" 0 $r.ExitCode

# 2j: Adjacent sections
Copy-Item (Join-Path $TmpDir 'adjacent-sections.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
# The passing command's OUTPUT (`before` / `after`) is now folded into the
# success JSON's commands_output on stdout (D65), not written to stderr.
Assert-Contains "adjacent: before_doing correct" 'before' $r.Stdout
Assert-NotContains "adjacent sections do not bleed" 'after' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "adjacent: after_doing correct" 'after' $r.Stdout

# ============================================================
# Test Group 3: Whitespace trimming
# ============================================================
Write-Host ""
Write-Host "=== Test Group 3: Whitespace trimming ==="

# Test the TrimStart behavior used in command list building.
# NOTE: the parameter must NOT be named $Input — that is a reserved automatic
# variable (the pipeline enumerator), so a positional bind to it silently
# misbehaves under Set-StrictMode -Version Latest.
function Test-TrimStart {
    param([string]$Text)
    return $Text.TrimStart()
}

Assert-Eq "trim leading spaces" "echo hello" (Test-TrimStart "   echo hello")
Assert-Eq "trim leading tabs" "echo hello" (Test-TrimStart "`t`techo hello")
Assert-Eq "trim mixed whitespace" "echo hello" (Test-TrimStart "`t  `techo hello")
Assert-Eq "no trim needed" "echo hello" (Test-TrimStart "echo hello")
Assert-Eq "all whitespace becomes empty" "" (Test-TrimStart "   ")
Assert-Eq "empty string stays empty" "" (Test-TrimStart "")

# ============================================================
# Test Group 4: Command list building
# ============================================================
Write-Host ""
Write-Host "=== Test Group 4: Command list building ==="

# Test the filtering logic: skip comments and blank lines
function Build-CmdList {
    param([string]$Commands)
    $result = @()
    foreach ($cmd in ($Commands -split "`n")) {
        $trimmed = $cmd.TrimStart()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $result += $trimmed
    }
    return $result
}

# @() guards the count against $null under Set-StrictMode -Version Latest:
# a function returning an empty array yields $null on assignment, and
# $null.Count is a hard error.
$commands = "# comment`necho `"step one`"`n   echo `"indented step`"`n`necho `"step three`"`n# trailing comment"
$result = @(Build-CmdList $commands)
Assert-Eq "filtered to 3 commands" "3" "$($result.Count)"
Assert-Eq "keeps step one" 'echo "step one"' $result[0]
Assert-Eq "trims indented step" 'echo "indented step"' $result[1]
Assert-Eq "keeps step three" 'echo "step three"' $result[2]

$commands = "# only comments`n`n# more comments`n"
$result = @(Build-CmdList $commands)
Assert-Eq "all comments filtered to empty" "0" "$($result.Count)"

# ============================================================
# Test Group 5: Full integration
# ============================================================
Write-Host ""
Write-Host "=== Test Group 5: Full integration ==="

$proj5 = Join-Path $TmpDir 'g5-project'
New-Item -ItemType Directory -Path $proj5 -Force | Out-Null
Set-Content -Path (Join-Path $proj5 '.stride.md') -Value @'
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
'@ -Encoding UTF8

# 5a: Claim triggers before_doing
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "claim exits 0" 0 $r.ExitCode
Assert-Contains "claim runs before_doing" "before_doing_executed" $r.Stdout

# 5b: Pre-complete triggers after_doing
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Exit "pre-complete exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "after_doing_executed" $r.Stdout

# 5c: Post-complete triggers before_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "post-complete exits 0" 0 $r.ExitCode
Assert-Contains "post-complete runs before_review" "before_review_executed" $r.Stdout

# 5d: Mark-reviewed triggers after_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "mark-reviewed exits 0" 0 $r.ExitCode
Assert-Contains "mark-reviewed runs after_review" "after_review_executed" $r.Stdout

# 5e: Non-stride command exits cleanly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"ls -la"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "non-stride exits 0" 0 $r.ExitCode
Assert-Eq "non-stride no stderr" "" $r.Stderr.Trim()

# 5f: No .stride.md exits cleanly
$emptyProj = Join-Path $TmpDir 'empty-project'
New-Item -ItemType Directory -Path $emptyProj -Force | Out-Null
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $emptyProj
Assert-Exit "no .stride.md exits 0" 0 $r.ExitCode

# 5g: No phase argument exits cleanly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase '' -ProjectDir $proj5
Assert-Exit "no phase exits 0" 0 $r.ExitCode

# 5h: Hook with failing command exits 2
$failProj = Join-Path $TmpDir 'fail-project'
New-Item -ItemType Directory -Path $failProj -Force | Out-Null
Set-Content -Path (Join-Path $failProj '.stride.md') -Value @'
## before_doing
```bash
echo "step one passes"
false
echo "step three should not run"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $failProj
Assert-Exit "failing hook exits 2" 2 $r.ExitCode
# The failure message stays on stderr — load-bearing for the PreToolUse blocking
# semantic (exit 2 + stderr message).
Assert-Contains "failing hook reports failure on stderr" "hook failed on command 2/3" $r.Stderr
# D65: the earlier PASSING command's output must NOT leak to stderr (and on the
# failure path it is not folded into commands_output either — the failed JSON
# carries only commands_completed/remaining).
Assert-NotContains "passing command output kept off stderr" "step one passes" $r.Stderr
Assert-NotContains "stops execution after failure" "step three should not run" $r.Stderr

# 5i: Hook with multiple successful commands
$multiProj = Join-Path $TmpDir 'multi-project'
New-Item -ItemType Directory -Path $multiProj -Force | Out-Null
Set-Content -Path (Join-Path $multiProj '.stride.md') -Value @'
## after_doing
```bash
echo "test_one"
echo "test_two"
echo "test_three"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $multiProj
Assert-Exit "multi-command exits 0" 0 $r.ExitCode
Assert-Contains "multi-command: step 1" "test_one" $r.Stdout
Assert-Contains "multi-command: step 2" "test_two" $r.Stdout
Assert-Contains "multi-command: step 3" "test_three" $r.Stdout

# 5j: Missing section exits 0
$partialProj = Join-Path $TmpDir 'partial-project'
New-Item -ItemType Directory -Path $partialProj -Force | Out-Null
Set-Content -Path (Join-Path $partialProj '.stride.md') -Value @'
## before_doing
```bash
echo "only before_doing"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $partialProj
Assert-Exit "missing section exits 0" 0 $r.ExitCode

# ============================================================
# Test Group 6: Edge cases
# ============================================================
Write-Host ""
Write-Host "=== Test Group 6: Edge cases ==="

# 6a: .stride.md with no trailing newline
$noNewlineProj = Join-Path $TmpDir 'no-newline-project'
New-Item -ItemType Directory -Path $noNewlineProj -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $noNewlineProj '.stride.md'),
    "## before_doing`n``````bash`necho `"no trailing newline`"`n``````",
    [System.Text.Encoding]::UTF8
)

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $noNewlineProj
Assert-Exit "no trailing newline exits 0" 0 $r.ExitCode
Assert-Contains "no trailing newline runs command" "no trailing newline" $r.Stdout

# 6b: Command with environment variable references
$envProj = Join-Path $TmpDir 'env-project'
New-Item -ItemType Directory -Path $envProj -Force | Out-Null
Set-Content -Path (Join-Path $envProj '.stride.md') -Value @'
## before_doing
```bash
echo "home=$HOME"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $envProj
Assert-Exit "env var expansion exits 0" 0 $r.ExitCode
Assert-Contains "env var expanded" "home=" $r.Stdout

# 6c: .stride.md with CRLF line endings
$crlfProj = Join-Path $TmpDir 'crlf-project'
New-Item -ItemType Directory -Path $crlfProj -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $crlfProj '.stride.md'),
    "## before_doing`r`n``````bash`r`necho `"crlf test`"`r`n```````r`n",
    [System.Text.Encoding]::UTF8
)

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $crlfProj
Assert-Exit "CRLF line endings exits 0" 0 $r.ExitCode
Assert-Contains "CRLF runs command" "crlf test" $r.Stdout

# 6d: JSON with tool_response (env caching path)
$cacheProj = Join-Path $TmpDir 'cache-project'
New-Item -ItemType Directory -Path $cacheProj -Force | Out-Null
Set-Content -Path (Join-Path $cacheProj '.stride.md') -Value @'
## before_doing
```bash
echo "id=$TASK_IDENTIFIER title=$TASK_TITLE"
```
'@ -Encoding UTF8

$claimWithResponse = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W99\",\"title\":\"Test Task\",\"status\":\"doing\",\"complexity\":\"small\",\"priority\":\"high\"}}"}'
$r = Invoke-HookScript -InputJson $claimWithResponse -Phase 'post' -ProjectDir $cacheProj
Assert-Exit "env caching exits 0" 0 $r.ExitCode
Assert-Contains "env cache: identifier" "id=W99" $r.Stdout
Assert-Contains "env cache: title" "title=Test Task" $r.Stdout
# Clean up cache
$cacheFile = Join-Path $cacheProj '.stride-env-cache'
if (Test-Path $cacheFile) { Remove-Item -Force $cacheFile }

# 6e: Structured JSON output on success
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "success JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "success JSON has status" '"success"' $r.Stdout
# D65: success JSON carries the per-command output array and writes no stderr.
Assert-Contains "success JSON has commands_output field" '"commands_output"' $r.Stdout
Assert-Eq "success path writes nothing to stderr" "" $r.Stderr.Trim()
$successObj = $r.Stdout | ConvertFrom-Json
Assert-Eq "success stdout parses to status success" "success" $successObj.status

# 6e2: D65 — a PASSING command that writes to STDERR (exit 0) is the exact
# production trigger. Its stderr must NOT reach fd 2 (where Claude Code
# mislabels it); it must land in the success JSON's commands_output[].stderr.
$stderrOkProj = Join-Path $TmpDir 'stderr-ok-project'
New-Item -ItemType Directory -Path $stderrOkProj -Force | Out-Null
Set-Content -Path (Join-Path $stderrOkProj '.stride.md') -Value @'
## before_doing
```bash
echo "compiling to stderr" 1>&2
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $stderrOkProj
Assert-Exit "stderr-writing passing gate exits 0" 0 $r.ExitCode
Assert-Eq "stderr-writing passing gate writes nothing to fd 2" "" $r.Stderr.Trim()
$soObj = $r.Stdout | ConvertFrom-Json
Assert-Contains "passing command's stderr folded into commands_output" "compiling to stderr" $soObj.commands_output[0].stderr

# 6f: Structured JSON output on failure
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $failProj
Assert-Contains "failure JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "failure JSON has failed status" '"failed"' $r.Stdout

# ============================================================
# Test Group 7: after_goal end-to-end routing (W790)
# ============================================================
# Mirrors test-stride-hook.sh Test Group 8. Each case constructs a
# realistic tool_input + tool_response payload and asserts on the
# script's actual stdout / stderr / exit code. Fixtures use generic
# synthetic URLs and task IDs per the W790 pitfall.
Write-Host ""
Write-Host "=== Test Group 7: after_goal end-to-end routing (W790) ==="

function Build-AfterGoalInput {
    param(
        [string]$PrimaryCommand,
        [string[]]$HookNames
    )
    $hooksArr = @($HookNames | ForEach-Object { @{ name = $_ } })
    $inner = (@{ data = @{ id = 99 }; hooks = $hooksArr } | ConvertTo-Json -Depth 5 -Compress)
    return (@{
        tool_input    = @{ command = $PrimaryCommand }
        tool_response = @{ stdout = $inner }
    } | ConvertTo-Json -Depth 5 -Compress)
}

$agProj = Join-Path $TmpDir 'after-goal-e2e'
New-Item -ItemType Directory -Path $agProj -Force | Out-Null
Set-Content -Path (Join-Path $agProj '.stride.md') -Value @'
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
'@ -Encoding UTF8

# 7a: after_goal in response + ## after_goal present -> section runs.
$agInputPresent = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -HookNames @('after_doing', 'before_review', 'after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProj
Assert-Exit "7a: end-to-end after_goal present exits 0" 0 $r.ExitCode
Assert-Contains "7a: primary before_review ran" "before_review_ran" $r.Stdout
Assert-Contains "7a: after_goal section ran" "after_goal_ran" $r.Stdout
Assert-Contains "7a: structured success JSON for after_goal on stdout" '"hook":"after_goal"' $r.Stdout

# 7b: after_goal in response + ## after_goal section ABSENT (back-compat).
$agProjMissing = Join-Path $TmpDir 'after-goal-e2e-missing'
New-Item -ItemType Directory -Path $agProjMissing -Force | Out-Null
Set-Content -Path (Join-Path $agProjMissing '.stride.md') -Value @'
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
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjMissing
Assert-Exit "7b: end-to-end after_goal-missing-section exits 0 (back-compat)" 0 $r.ExitCode
Assert-Contains "7b: primary before_review still ran" "before_review_ran" $r.Stdout
Assert-NotContains "7b: missing ## after_goal emits no after_goal JSON" '"hook":"after_goal"' $r.Stdout

# 7c: after_goal NOT in response -> behavior unchanged.
$agInputAbsent = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -HookNames @('after_doing', 'before_review', 'after_review')
$r = Invoke-HookScript -InputJson $agInputAbsent -Phase 'post' -ProjectDir $agProj
Assert-Exit "7c: end-to-end after_goal-absent exits 0" 0 $r.ExitCode
Assert-Contains "7c: primary before_review ran" "before_review_ran" $r.Stdout
Assert-NotContains "7c: after_goal absent does not execute the section" "after_goal_ran" $r.Stdout

# 7d: after_goal section command exits non-zero -> structured failure JSON
# surfaces on stdout; script exit code stays 0.
$agProjFail = Join-Path $TmpDir 'after-goal-e2e-fail'
New-Item -ItemType Directory -Path $agProjFail -Force | Out-Null
Set-Content -Path (Join-Path $agProjFail '.stride.md') -Value @'
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
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjFail
Assert-Exit "7d: end-to-end after_goal-failure does not propagate as script exit" 0 $r.ExitCode
Assert-Contains "7d: structured failed JSON references after_goal on stdout" '"hook":"after_goal"' $r.Stdout
Assert-Contains "7d: structured failed JSON has status:failed" '"status":"failed"' $r.Stdout
Assert-Contains "7d: structured failed JSON carries non-zero exit_code" '"exit_code":11' $r.Stdout

# 7e: mark_reviewed URL also routes after_goal.
$agInputMr = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' `
    -HookNames @('after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agInputMr -Phase 'post' -ProjectDir $agProj
Assert-Exit "7e: end-to-end after_goal on mark_reviewed exits 0" 0 $r.ExitCode
Assert-Contains "7e: mark_reviewed runs after_review" "after_review_ran" $r.Stdout
Assert-Contains "7e: mark_reviewed runs after_goal" "after_goal_ran" $r.Stdout

# --- W1512: after_goal hook.env forwarding ---
# Helper: build a payload whose after_goal hook entry carries a server-supplied
# `env` object. Mirrors Build-AfterGoalInput but attaches env to the after_goal
# entry so the assertions can confirm the bridge exports it. -Depth 5 keeps the
# nested env hashtable intact through ConvertTo-Json.
function Build-AfterGoalInputWithEnv {
    param(
        [string]$PrimaryCommand,
        [hashtable]$Env
    )
    $hooksArr = @(
        @{ name = 'after_review' }
        @{ name = 'after_goal'; env = $Env }
    )
    $inner = (@{ data = @{ id = 99 }; hooks = $hooksArr } | ConvertTo-Json -Depth 5 -Compress)
    return (@{
        tool_input    = @{ command = $PrimaryCommand }
        tool_response = @{ stdout = $inner }
    } | ConvertTo-Json -Depth 5 -Compress)
}

# Fixture whose after_goal section echoes every forwarded variable so the
# assertions can confirm each reached the section process environment.
$agEnvProj = Join-Path $TmpDir 'after-goal-env'
New-Item -ItemType Directory -Path $agEnvProj -Force | Out-Null
Set-Content -Path (Join-Path $agEnvProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal_id=$GOAL_ID id=$GOAL_IDENTIFIER title=$GOAL_TITLE desc=$GOAL_DESCRIPTION board=$BOARD_ID col=$COLUMN_ID agent=$AGENT_NAME"
```
'@ -Encoding UTF8

# 7f: a stubbed hook.env with GOAL_*/BOARD_*/COLUMN_*/AGENT_NAME reaches the
# after_goal section environment, copied VERBATIM (spaces preserved).
$agEnvInput = Build-AfterGoalInputWithEnv `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -Env @{
        GOAL_ID          = '4687'
        GOAL_IDENTIFIER  = 'G4687'
        GOAL_TITLE       = 'Ship the bridge'
        GOAL_DESCRIPTION = 'Wire GOAL_* through'
        BOARD_ID         = '55'
        COLUMN_ID        = '128'
        AGENT_NAME       = 'Claude Opus 4.8'
    }
$r = Invoke-HookScript -InputJson $agEnvInput -Phase 'post' -ProjectDir $agEnvProj
Assert-Exit "7f: after_goal env-export exits 0" 0 $r.ExitCode
Assert-Contains "7f: GOAL_ID exported verbatim" "goal_id=4687" $r.Stdout
Assert-Contains "7f: GOAL_IDENTIFIER exported verbatim" "id=G4687" $r.Stdout
Assert-Contains "7f: GOAL_TITLE with spaces exported verbatim" "title=Ship the bridge" $r.Stdout
Assert-Contains "7f: GOAL_DESCRIPTION exported verbatim" "desc=Wire GOAL_* through" $r.Stdout
Assert-Contains "7f: BOARD_ID exported verbatim" "board=55" $r.Stdout
Assert-Contains "7f: COLUMN_ID exported verbatim" "col=128" $r.Stdout
Assert-Contains "7f: AGENT_NAME with spaces exported verbatim" "agent=Claude Opus 4.8" $r.Stdout

# 7g: an after_goal entry with NO env object is a clean no-op — the section
# still runs (exit 0) with the GOAL_* vars empty, never an error. Uses a FRESH
# project dir so the (W1612) env-cache GOAL_* persisted by 7f above does not leak
# in via the env-cache load — 7g must observe a genuinely empty GOAL_*.
$agNoEnvProj = Join-Path $TmpDir 'after-goal-noenv'
New-Item -ItemType Directory -Path $agNoEnvProj -Force | Out-Null
Copy-Item (Join-Path $agEnvProj '.stride.md') (Join-Path $agNoEnvProj '.stride.md')
$agNoEnvInput = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -HookNames @('after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agNoEnvInput -Phase 'post' -ProjectDir $agNoEnvProj
Assert-Exit "7g: after_goal missing env is a clean no-op (exit 0)" 0 $r.ExitCode
Assert-Contains "7g: section still runs with empty GOAL_* vars" "goal_id= id= title=" $r.Stdout

# ============================================================
# Test Group 8: PUT snapshot upload (W839 — G162 port)
# ============================================================
# Mirror of stride/hooks/test-stride-hook.ps1 Test Group 7. Verifies
# Invoke-FinalizeAfterDoing PUTs the on-disk snapshot to
# {URL}/api/tasks/{TASK_ID}/changed_files when all prerequisites are
# present, and silently no-ops otherwise.
Write-Host ""
Write-Host "=== Test Group 8: PUT snapshot upload (W839) ==="

# 8a: PUT-success — snapshot uploaded to a local HttpListener
$putSuccessProj = Join-Path $TmpDir 'put-success-project'
New-Item -ItemType Directory -Path $putSuccessProj -Force | Out-Null
Set-Content -Path (Join-Path $putSuccessProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $putSuccessProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"unified patch body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $putSuccessProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

$putPort = 18879
$putFixture = Join-Path $TmpDir 'put-fixture.json'
if (Test-Path $putFixture) { Remove-Item -Force $putFixture }

$putListenerJob = Start-Job -ArgumentList $putPort, $putFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{
            Method = $req.HttpMethod
            Path   = $req.Url.AbsolutePath
            Auth   = $req.Headers['Authorization']
            Body   = $body
        } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $putPort
    $putCompleteCmd = "curl -X PATCH http://localhost:$putPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_xyz`""
    # ConvertTo-Json escapes the command's embedded quotes — hand-rolling the
    # JSON here produces an invalid document whose fallback-regex extraction
    # truncates the command at the first inner quote, dropping the token.
    $putJson = @{ tool_input = @{ command = $putCompleteCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $putJson -Phase 'pre' -ProjectDir $putSuccessProj
    Assert-Exit "8a: hook exits 0 after PUT" 0 $r.ExitCode

    Wait-Job $putListenerJob -Timeout 8 | Out-Null
    Remove-Job $putListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $putFixture) {
        $record = Get-Content -Raw -Path $putFixture | ConvertFrom-Json
        Assert-Eq "8a: PUT method" "PUT" $record.Method
        Assert-Contains "8a: PUT path targets /changed_files" "/api/tasks/99/changed_files" $record.Path
        Assert-Eq "8a: Bearer token from `$Command" "Bearer test_token_xyz" $record.Auth
        # D61: body's changed_files value is the transport-encoded envelope
        # {encoding: "base64", data: <string>}, NOT a bare array and NOT raw
        # diff text (an edge filter could misread the raw text as an attack).
        try {
            $parsedBody = $record.Body | ConvertFrom-Json
            if ($parsedBody.changed_files.encoding -eq 'base64' -and
                $parsedBody.changed_files.data -is [string] -and
                $parsedBody.changed_files.data.Length -gt 0) {
                Write-Host "  PASS: 8a: PUT body is the base64-encoded changed_files envelope" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 8a: PUT body is not the encoded envelope: $($record.Body)" -ForegroundColor Red
                $script:FAIL++
            }

            # D61: the raw diff/path text MUST NOT appear in the wire body.
            if ($record.Body -like '*foo.txt*') {
                Write-Host "  FAIL: 8a: raw path leaked into the wire body (should be base64-encoded)" -ForegroundColor Red
                $script:FAIL++
            } else {
                Write-Host "  PASS: 8a: raw diff text is absent from the wire body (encoded)" -ForegroundColor Green
                $script:PASS++
            }

            # D61: round-trip — encoding the snapshot bytes the same way the hook
            # does reproduces the envelope's data field.
            $expectedData = [System.Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes((Join-Path $putSuccessProj '.stride-changed-files.json')))
            if ($parsedBody.changed_files.data -eq $expectedData) {
                Write-Host "  PASS: 8a: encoded data round-trips to the snapshot file content" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 8a: round-trip mismatch — data: $($parsedBody.changed_files.data) vs expected: $expectedData" -ForegroundColor Red
                $script:FAIL++
            }
        } catch {
            Write-Host "  FAIL: 8a: PUT body did not parse as JSON: $($_.Exception.Message)" -ForegroundColor Red
            $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 8a: PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($putListenerJob -and $putListenerJob.State -eq 'Running') {
        Stop-Job $putListenerJob -ErrorAction SilentlyContinue
        Remove-Job $putListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 8b: PUT failure (unreachable URL) does not propagate
$putFailProj = Join-Path $TmpDir 'put-fail-project'
New-Item -ItemType Directory -Path $putFailProj -Force | Out-Null
Set-Content -Path (Join-Path $putFailProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $putFailProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $putFailProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

$failCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$failJson = @{ tool_input = @{ command = $failCmd } } | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $failJson -Phase 'pre' -ProjectDir $putFailProj
Assert-Exit "8b: hook exits 0 even when PUT fails" 0 $r.ExitCode
# D61: a failed upload is surfaced to stderr (non-fatal), never silently dropped.
# Invoke-ChangedFilesUpload (W1094) now includes the HTTP code in the warning
# ('000' on a transport failure like this unreachable port).
Assert-Contains "8b: failed PUT warns to stderr" "changed_files upload failed (HTTP" $r.Stderr
$snapshotPath8b = Join-Path $putFailProj '.stride-changed-files.json'
if (Test-Path $snapshotPath8b) {
    Write-Host "  PASS: 8b: snapshot file persists across failed PUT" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 8b: snapshot file missing after failed PUT" -ForegroundColor Red
    $script:FAIL++
}

# 8c: No snapshot file on disk → Invoke-FinalizeAfterDoing no-ops cleanly
$noSnapProj = Join-Path $TmpDir 'no-snap-project'
New-Item -ItemType Directory -Path $noSnapProj -Force | Out-Null
Set-Content -Path (Join-Path $noSnapProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noSnapProj '.stride-env-cache') `
    -Value "TASK_ID=99" -Encoding UTF8
$noSnapCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$noSnapJson = "{`"tool_input`":{`"command`":`"$noSnapCmd`"}}"
$r = Invoke-HookScript -InputJson $noSnapJson -Phase 'pre' -ProjectDir $noSnapProj
Assert-Exit "8c: hook exits 0 with no snapshot file" 0 $r.ExitCode

# 8d: No Bearer token in `$Command → finalize no-ops
$noTokProj = Join-Path $TmpDir 'no-tok-project'
New-Item -ItemType Directory -Path $noTokProj -Force | Out-Null
Set-Content -Path (Join-Path $noTokProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noTokProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $noTokProj '.stride-env-cache') `
    -Value "TASK_ID=99" -Encoding UTF8
$noTokCmd = 'curl -X PATCH http://stride.example.com/api/tasks/99/complete'
$noTokJson = "{`"tool_input`":{`"command`":`"$noTokCmd`"}}"
$r = Invoke-HookScript -InputJson $noTokJson -Phase 'pre' -ProjectDir $noTokProj
Assert-Exit "8d: hook exits 0 with no Bearer token" 0 $r.ExitCode

# 8e (D127): No TASK_ID in the env cache. The /complete URL carries id 99, so
# finalize now targets that URL id (env-cache-independent) rather than no-opping.
# The host is unreachable here, so the PUT fails silently and the hook still
# exits 0 — the targeting itself is asserted by the dedicated listener test 8g.
$noIdProj = Join-Path $TmpDir 'no-id-project'
New-Item -ItemType Directory -Path $noIdProj -Force | Out-Null
Set-Content -Path (Join-Path $noIdProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noIdProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $noIdProj '.stride-env-cache') `
    -Value "TASK_BASE_REF=abc" -Encoding UTF8
$noIdCmd = 'curl -X PATCH http://stride.example.com/api/tasks/99/complete -H "Authorization: Bearer tok"'
$noIdJson = "{`"tool_input`":{`"command`":`"$noIdCmd`"}}"
$r = Invoke-HookScript -InputJson $noIdJson -Phase 'pre' -ProjectDir $noIdProj
Assert-Exit "8e: hook exits 0 with no TASK_ID" 0 $r.ExitCode

# 8f (D67): Invoke-ChangedFilesUpload strips the hook's own root artifacts from
# the snapshot before PUT. The ps1 has no capture step, so this upload-side
# filter is the equivalent enforcement point. A same-named file in a
# subdirectory is kept; the legitimate change is kept.
$exclProj = Join-Path $TmpDir 'put-exclude-project'
New-Item -ItemType Directory -Path $exclProj -Force | Out-Null
Set-Content -Path (Join-Path $exclProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-changed-files.json') `
    -Value '[{"path":".stride-diff-upload-state","diff":"state body"},{"path":"lib/foo.ex","diff":"real patch"},{"path":"sub/.stride-changed-files.json","diff":"user file"},{"path":".stride-changed-files.json","diff":"snapshot body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

$exclPort = 18882
$exclFixture = Join-Path $TmpDir 'put-exclude-fixture.json'
if (Test-Path $exclFixture) { Remove-Item -Force $exclFixture }

$exclListenerJob = Start-Job -ArgumentList $exclPort, $exclFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $exclPort
    $exclCmd = "curl -X PATCH http://localhost:$exclPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_xyz`""
    $exclJson = @{ tool_input = @{ command = $exclCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $exclJson -Phase 'pre' -ProjectDir $exclProj
    Assert-Exit "8f: hook exits 0 after filtered PUT" 0 $r.ExitCode

    Wait-Job $exclListenerJob -Timeout 8 | Out-Null
    Remove-Job $exclListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $exclFixture) {
        $record = Get-Content -Raw -Path $exclFixture | ConvertFrom-Json
        $parsedBody = $record.Body | ConvertFrom-Json
        $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
        $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
        $entries = @($decodedText | ConvertFrom-Json)
        $paths = @($entries | ForEach-Object { $_.path })
        Assert-Eq "8f: filtered snapshot keeps only the non-artifact entries" "2" "$($entries.Count)"
        if ($paths -contains 'lib/foo.ex' -and $paths -contains 'sub/.stride-changed-files.json') {
            Write-Host "  PASS: 8f: real file and subdir same-named file survive the filter" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 8f: expected lib/foo.ex + sub/.stride-changed-files.json, got: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
        if ($paths -notcontains '.stride-diff-upload-state' -and $paths -notcontains '.stride-changed-files.json') {
            Write-Host "  PASS: 8f: root upload-state and snapshot artifacts stripped from PUT body" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 8f: root artifacts leaked into PUT body: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 8f: filtered PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($exclListenerJob -and $exclListenerJob.State -eq 'Running') {
        Stop-Job $exclListenerJob -ErrorAction SilentlyContinue
        Remove-Job $exclListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 8g (D127): finalize PUTs to the task id in the /complete URL, NOT a stale
# env-cache TASK_ID. Env cache says 111 (a previous task); the completion URL
# says 99 → the PUT must target /api/tasks/99/changed_files. This is the fix for
# the empty-changed_files root cause: a hidden claim leaves a stale env TASK_ID,
# and before D127 the diff was PUT to that wrong task.
$d127Proj = Join-Path $TmpDir 'd127-url-id-project'
New-Item -ItemType Directory -Path $d127Proj -Force | Out-Null
Set-Content -Path (Join-Path $d127Proj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $d127Proj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
# STALE env cache — a previous task's id.
Set-Content -Path (Join-Path $d127Proj '.stride-env-cache') `
    -Value "TASK_ID=111`nTASK_BASE_REF=abc" -Encoding UTF8

$d127Port = 18879
$d127Fixture = Join-Path $TmpDir 'd127-fixture.json'
if (Test-Path $d127Fixture) { Remove-Item -Force $d127Fixture }
$d127Job = Start-Job -ArgumentList $d127Port, $d127Fixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start(); $ctx = $l.GetContext(); $req = $ctx.Request
        @{ Path = $req.Url.AbsolutePath } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response; $resp.StatusCode = 200; $resp.OutputStream.Close()
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
try {
    $null = Wait-ForListener -Port $d127Port
    $d127Cmd = "curl -X PATCH http://localhost:$d127Port/api/tasks/99/complete -H `"Authorization: Bearer tok`""
    $d127Json = @{ tool_input = @{ command = $d127Cmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d127Json -Phase 'pre' -ProjectDir $d127Proj
    Assert-Exit "8g: hook exits 0 after PUT" 0 $r.ExitCode
    Wait-Job $d127Job -Timeout 8 | Out-Null
    Remove-Job $d127Job -Force -ErrorAction SilentlyContinue
    $d127Path = if (Test-Path $d127Fixture) { (Get-Content -Raw -Path $d127Fixture | ConvertFrom-Json).Path } else { '' }
    Assert-Contains "8g (D127): PUT targets the URL task id (99), not the stale env id (111)" "/api/tasks/99/changed_files" $d127Path
    Assert-NotContains "8g (D127): PUT does not target the stale env id (111)" "/api/tasks/111/changed_files" $d127Path
} finally {
    Remove-Job $d127Job -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Test Group 9: early upload + before_review self-heal (W1095,
# mirrors test-stride-hook.sh Groups 11 and 12)
# ============================================================
# The ps1 script has no capture step — the pre-seeded on-disk snapshot is the
# source of truth — so the bash capture-content assertions translate to
# upload-ordering and state-file assertions here. Unreachable-URL cases use
# 127.0.0.1:1 so an attempted PUT deterministically records '000' and warns on
# stderr; listener cases serve multiple requests because after_doing now PUTs
# twice (early + refresh). Passing-command output is forwarded to stderr (the
# copilot idiom), so command-output assertions read $r.Stderr, not $r.Stdout.
Write-Host ""
Write-Host "=== Test Group 9: early upload + self-heal (W1095) ==="

# Listener that serves $Count requests, appending one compressed JSON record
# per request to $Fixture (JSON-lines).
function Start-PutListener {
    param([int]$Port, [string]$Fixture, [int]$Count = 1)
    Start-Job -ArgumentList $Port, $Fixture, $Count -ScriptBlock {
        param($Port, $Fixture, $Count)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            for ($i = 0; $i -lt $Count; $i++) {
                $ctx = $l.GetContext()
                $req = $ctx.Request
                $reader = [System.IO.StreamReader]::new($req.InputStream)
                $body = $reader.ReadToEnd()
                @{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath; Auth = $req.Headers['Authorization']; Body = $body } |
                    ConvertTo-Json -Compress | Add-Content -Path $Fixture -Encoding UTF8
                $ctx.Response.StatusCode = 200
                $ctx.Response.OutputStream.Close()
            }
        } catch {
            # Listener tear-down errors are ignored.
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
}

function New-SelfHealProject {
    param([string]$Name, [string]$StrideMd)
    $dir = Join-Path $TmpDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path (Join-Path $dir '.stride.md') -Value $StrideMd -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride-changed-files.json') `
        -Value '[{"path":"foo.txt","diff":"unified patch body"}]' -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride-env-cache') `
        -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8
    return $dir
}

$shUnreachableCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$shUnreachableJson = @{ tool_input = @{ command = $shUnreachableCmd } } | ConvertTo-Json -Compress

# 9a: early-upload ordering — the FIRST section command finds the upload state
# (written by the early PUT attempt) already on disk.
$shProjA = New-SelfHealProject -Name 'sh-early-order' -StrideMd @'
## after_doing
```bash
cp .stride-diff-upload-state early-state.txt
```
'@
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'pre' -ProjectDir $shProjA
Assert-Exit "9a: after_doing section succeeds with early upload attempt" 0 $r.ExitCode
$earlyState = Get-Content -Raw -Path (Join-Path $shProjA 'early-state.txt') -ErrorAction SilentlyContinue
if ($earlyState -and $earlyState.Contains('task_id=99')) {
    Write-Host "  PASS: 9a: upload state existed BEFORE the first section command ran" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9a: first section command did not find the upload state: $earlyState" -ForegroundColor Red
    $script:FAIL++
}
Assert-NotContains "9a: early upload emits nothing on stdout" "task_id" $r.Stdout
Assert-Contains "9a: structured success JSON still on stdout" '"status":"success"' $r.Stdout

# 9b: GLOBAL HookName gate — running the after_goal SECTION while the primary
# hook is after_review must attempt no upload (no stderr warning). The
# unreachable URL would warn if the gate were broken.
$shProjB = New-SelfHealProject -Name 'sh-gate' -StrideMd @'
## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "after_goal_ran"
```
'@
$shGateResponse = '{"data":{"id":99},"hooks":[{"name":"after_goal"}]}'
$shGateJson = @{
    tool_input = @{ command = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/mark_reviewed -H "Authorization: Bearer tok"' }
    tool_response = $shGateResponse
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $shGateJson -Phase 'post' -ProjectDir $shProjB
Assert-Exit "9b: mark_reviewed with after_goal exits 0" 0 $r.ExitCode
# Passing-command output is forwarded to stderr in copilot (canonical folds it
# into the stdout commands_output array instead).
Assert-Contains "9b: after_goal section ran" "after_goal_ran" ($r.Stderr + $r.Stdout)
Assert-NotContains "9b: no upload attempted when HookName is not after_doing" "changed_files upload failed" $r.Stderr

# 9c: failing section command — structured failed JSON and exit 2 are
# preserved, with the early upload attempt already recorded (mirrors 11d).
$shProjC = New-SelfHealProject -Name 'sh-failed-gate' -StrideMd @'
## after_doing
```bash
bash -c 'exit 7'
```
'@
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'pre' -ProjectDir $shProjC
Assert-Exit "9c: failing after_doing command still returns 2" 2 $r.ExitCode
Assert-Contains "9c: structured failed JSON emitted" '"status":"failed"' $r.Stdout
Assert-Contains "9c: failed JSON carries exit_code 7" '"exit_code":7' $r.Stdout
$stateC = Get-Content -Raw -Path (Join-Path $shProjC '.stride-diff-upload-state') -ErrorAction SilentlyContinue
if ($stateC -and $stateC.Contains('task_id=99') -and $stateC.Contains('http_code=000')) {
    Write-Host "  PASS: 9c: early upload state survives a failed quality gate" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9c: state missing or wrong after failed gate: $stateC" -ForegroundColor Red
    $script:FAIL++
}

# 9d: state file records the real HTTP code, carries no credentials, and
# after_doing PUTs exactly twice (early + refresh) — mirrors 12a/12b and the
# bash 9a two-PUT assertion.
$shProjD = New-SelfHealProject -Name 'sh-state-2xx' -StrideMd @'
## after_doing
```bash
echo "ran"
```
'@
$shPortD = 18890
$shFixtureD = Join-Path $TmpDir 'sh-fixture-d.jsonl'
if (Test-Path $shFixtureD) { Remove-Item -Force $shFixtureD }
$shJobD = Start-PutListener -Port $shPortD -Fixture $shFixtureD -Count 2
try {
    $null = Wait-ForListener -Port $shPortD
    $shJsonD = @{ tool_input = @{ command = "curl -X PATCH http://localhost:$shPortD/api/tasks/99/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $shJsonD -Phase 'pre' -ProjectDir $shProjD
    Assert-Exit "9d: after_doing with listener exits 0" 0 $r.ExitCode
    Wait-Job $shJobD -Timeout 8 | Out-Null
    Remove-Job $shJobD -Force -ErrorAction SilentlyContinue
    $putCount = 0
    if (Test-Path $shFixtureD) { $putCount = @(Get-Content $shFixtureD).Count }
    Assert-Eq "9d: early upload + refresh make exactly two PUT calls" "2" "$putCount"
    $stateD = Get-Content -Raw -Path (Join-Path $shProjD '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    Assert-Contains "9d: state records the task id" "task_id=99" $stateD
    Assert-Contains "9d: state records the 2xx outcome" "http_code=200" $stateD
    if ($stateD -and ($stateD -match 'Bearer|https?://')) {
        Write-Host "  FAIL: 9d: state file leaked a credential or URL: $stateD" -ForegroundColor Red
        $script:FAIL++
    } else {
        Write-Host "  PASS: 9d: state file carries no token or URL" -ForegroundColor Green
        $script:PASS++
    }
} finally {
    if ($shJobD -and $shJobD.State -eq 'Running') {
        Stop-Job $shJobD -ErrorAction SilentlyContinue
        Remove-Job $shJobD -Force -ErrorAction SilentlyContinue
    }
}

# 9e: before_review retries when NO state file exists — the PUT arrives and the
# outcome is recorded (mirrors 12c).
$shProjE = New-SelfHealProject -Name 'sh-retry-missing' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
$shPortE = 18891
$shFixtureE = Join-Path $TmpDir 'sh-fixture-e.jsonl'
if (Test-Path $shFixtureE) { Remove-Item -Force $shFixtureE }
$shJobE = Start-PutListener -Port $shPortE -Fixture $shFixtureE -Count 1
try {
    $null = Wait-ForListener -Port $shPortE
    $shJsonE = @{ tool_input = @{ command = "curl -X PATCH http://localhost:$shPortE/api/tasks/99/complete -H `"Authorization: Bearer tok`"" } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $shJsonE -Phase 'post' -ProjectDir $shProjE
    Assert-Exit "9e: before_review with missing state exits 0" 0 $r.ExitCode
    Wait-Job $shJobE -Timeout 8 | Out-Null
    Remove-Job $shJobE -Force -ErrorAction SilentlyContinue
    if (Test-Path $shFixtureE) {
        $recE = Get-Content -Raw -Path $shFixtureE | ConvertFrom-Json
        Assert-Eq "9e: retry PUT method" "PUT" $recE.Method
        Assert-Contains "9e: retry PUT targets /changed_files" "/api/tasks/99/changed_files" $recE.Path
    } else {
        Write-Host "  FAIL: 9e: no retry PUT arrived for missing state" -ForegroundColor Red
        $script:FAIL++
    }
    $stateE = Get-Content -Raw -Path (Join-Path $shProjE '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    Assert-Contains "9e: retry outcome recorded" "http_code=200" $stateE
} finally {
    if ($shJobE -and $shJobE.State -eq 'Running') {
        Stop-Job $shJobE -ErrorAction SilentlyContinue
        Remove-Job $shJobE -Force -ErrorAction SilentlyContinue
    }
}

# 9f: no re-upload on a healthy 2xx for the current task (mirrors 12d) — with an
# unreachable URL an attempted retry would warn and rewrite the state to 000; a
# healthy skip leaves both untouched.
$shProjF = New-SelfHealProject -Name 'sh-healthy' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
Set-Content -Path (Join-Path $shProjF '.stride-diff-upload-state') `
    -Value "task_id=99`nhttp_code=200" -Encoding UTF8
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjF
Assert-Exit "9f: healthy-state before_review exits 0" 0 $r.ExitCode
Assert-NotContains "9f: no retry attempted on recorded 2xx" "changed_files upload failed" $r.Stderr
$stateF = Get-Content -Raw -Path (Join-Path $shProjF '.stride-diff-upload-state') -ErrorAction SilentlyContinue
Assert-Contains "9f: healthy state left untouched" "http_code=200" $stateF

# 9g: retry on a state naming a DIFFERENT task id, and on a recorded non-2xx
# (mirrors 12e/12f) — the unreachable URL records the attempt as 000 and warns.
$shProjG = New-SelfHealProject -Name 'sh-stale-id' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
Set-Content -Path (Join-Path $shProjG '.stride-diff-upload-state') `
    -Value "task_id=88`nhttp_code=200" -Encoding UTF8
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjG
Assert-Contains "9g: stale task id triggers the retry (warning emitted)" "changed_files upload failed" $r.Stderr
$stateG = Get-Content -Raw -Path (Join-Path $shProjG '.stride-diff-upload-state') -ErrorAction SilentlyContinue
Assert-Contains "9g: state rewritten for the current task" "task_id=99" $stateG

$shProjG2 = New-SelfHealProject -Name 'sh-non2xx' -StrideMd @'
## before_review
```bash
echo "br_ran"
```
'@
Set-Content -Path (Join-Path $shProjG2 '.stride-diff-upload-state') `
    -Value "task_id=99`nhttp_code=503" -Encoding UTF8
$r = Invoke-HookScript -InputJson $shUnreachableJson -Phase 'post' -ProjectDir $shProjG2
Assert-Contains "9g: recorded non-2xx triggers the retry (warning emitted)" "changed_files upload failed" $r.Stderr
Assert-Exit "9g: failed retry never fails the before_review hook" 0 $r.ExitCode

# 9h: claim refresh removes the previous task's snapshot and upload state
# (mirrors 12h and the bash claim-refresh rm sites).
$shProjH = Join-Path $TmpDir 'sh-claim-cleanup'
New-Item -ItemType Directory -Path $shProjH -Force | Out-Null
Set-Content -Path (Join-Path $shProjH '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $shProjH '.stride-changed-files.json') `
    -Value '[{"path":"stale.txt","diff":"old"}]' -Encoding UTF8
Set-Content -Path (Join-Path $shProjH '.stride-diff-upload-state') `
    -Value "task_id=88`nhttp_code=200" -Encoding UTF8
$shClaimJson = @{
    tool_input = @{ command = 'curl -X POST https://stridelikeaboss.com/api/tasks/claim' }
    tool_response = '{"data":{"id":42,"identifier":"W42","title":"T","status":"in_progress","complexity":"small","priority":"low"}}'
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $shClaimJson -Phase 'post' -ProjectDir $shProjH
Assert-Exit "9h: claim refresh exits 0" 0 $r.ExitCode
if (-not (Test-Path (Join-Path $shProjH '.stride-diff-upload-state'))) {
    Write-Host "  PASS: 9h: claim refresh removes the previous task's upload state" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9h: stale upload state survived the claim refresh" -ForegroundColor Red
    $script:FAIL++
}
if (-not (Test-Path (Join-Path $shProjH '.stride-changed-files.json'))) {
    Write-Host "  PASS: 9h: claim refresh removes the previous task's snapshot" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9h: stale snapshot survived the claim refresh" -ForegroundColor Red
    $script:FAIL++
}

# 9i: after_review cleanup removes the snapshot and upload state (mirrors 12i).
$shProjI = Join-Path $TmpDir 'sh-review-cleanup'
New-Item -ItemType Directory -Path $shProjI -Force | Out-Null
Set-Content -Path (Join-Path $shProjI '.stride.md') -Value @'
## after_review
```bash
echo "reviewed"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $shProjI '.stride-changed-files.json') `
    -Value '[{"path":"stale.txt","diff":"old"}]' -Encoding UTF8
Set-Content -Path (Join-Path $shProjI '.stride-diff-upload-state') `
    -Value "task_id=99`nhttp_code=200" -Encoding UTF8
$shReviewJson = @{ tool_input = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' } } | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $shReviewJson -Phase 'post' -ProjectDir $shProjI
Assert-Exit "9i: after_review cleanup exits 0" 0 $r.ExitCode
if (-not (Test-Path (Join-Path $shProjI '.stride-diff-upload-state'))) {
    Write-Host "  PASS: 9i: after_review cleanup removes the upload state" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9i: upload state survived the after_review cleanup" -ForegroundColor Red
    $script:FAIL++
}
if (-not (Test-Path (Join-Path $shProjI '.stride-changed-files.json'))) {
    Write-Host "  PASS: 9i: after_review cleanup removes the snapshot" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 9i: snapshot survived the after_review cleanup" -ForegroundColor Red
    $script:FAIL++
}

# 9j (W1658): before_review self-heal TERMINAL failure — when the last retry PUT
# returns non-2xx, the hook prints a loud UNRESOLVED warning on stderr AND marks
# the state file `unresolved=yes` (a definitively-lost diff is never silently
# swallowed). The hook exit code is unchanged (the completion still succeeds).
$w1658Proj = Join-Path $TmpDir 'sh-w1658-terminal'
New-Item -ItemType Directory -Path $w1658Proj -Force | Out-Null
Set-Content -Path (Join-Path $w1658Proj '.stride.md') -Value @'
## before_review
```bash
echo "reviewing"
```
'@ -Encoding UTF8
# Pre-existing snapshot (the ps1 self-heal re-PUTs the on-disk snapshot; it does
# not re-capture). No state file → the self-heal retries.
Set-Content -Path (Join-Path $w1658Proj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8

$w1658Port = 18883
$w1658Job = Start-Job -ArgumentList $w1658Port -ScriptBlock {
    param($Port)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start(); $ctx = $l.GetContext()
        $resp = $ctx.Response; $resp.StatusCode = 500; $resp.OutputStream.Close()
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
try {
    $null = Wait-ForListener -Port $w1658Port
    $w1658Cmd = "curl -X PATCH http://localhost:$w1658Port/api/tasks/77/complete -H `"Authorization: Bearer tok`""
    $w1658Json = @{ tool_input = @{ command = $w1658Cmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $w1658Json -Phase 'post' -ProjectDir $w1658Proj
    Wait-Job $w1658Job -Timeout 8 | Out-Null
    Remove-Job $w1658Job -Force -ErrorAction SilentlyContinue
    Assert-Exit "9j (W1658): terminal self-heal failure never fails the hook" 0 $r.ExitCode
    Assert-Contains "9j (W1658): terminal self-heal failure prints a loud UNRESOLVED warning" "CHANGED_FILES UPLOAD UNRESOLVED" $r.Stderr
    $w1658StateFile = Join-Path $w1658Proj '.stride-diff-upload-state'
    $w1658State = if (Test-Path $w1658StateFile) { Get-Content -Raw -Path $w1658StateFile } else { '' }
    Assert-Contains "9j (W1658): state file marked unresolved on terminal failure" "unresolved=yes" $w1658State
} finally {
    Remove-Job $w1658Job -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Test Group 10: claim-time TASK_BASE_REF refresh + persisted-output
# fallback (W1087, mirrors test-stride-hook.sh Test Group 13 test-for-test)
# ============================================================
# A claim always opens a new task window. The hook must refresh TASK_BASE_REF
# to current HEAD on every claim: from parseable stdout, from a persisted output
# file when stdout only carries a "saved to" notice, and — when no JSON is
# obtainable at all — by rewriting only the TASK_BASE_REF line while preserving
# existing TASK_ identity lines. Non-claim hooks never touch it.
Write-Host ""
Write-Host "=== Test Group 10: claim TASK_BASE_REF refresh (W1087) ==="

# A real two-commit git repo with the stride state files gitignored, a pre-seeded
# cache carrying a STALE base ref (the v1 commit) and a TASK_ID line to prove
# preservation. The ps1 test suite had no git-backed fixtures before this group.
function New-GitRepo {
    param([string]$Name)
    $dir = Join-Path $TmpDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & git -C $dir init -q 2>$null | Out-Null
    & git -C $dir config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $dir config user.name 'Test' 2>$null | Out-Null
    & git -C $dir config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $dir '.gitignore') `
        -Value ".stride.md`n.stride-env-cache`n.stride-changed-files.json`n.stride-diff-upload-state" -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'tracked.txt') -Value 'v1' -Encoding UTF8
    & git -C $dir add .gitignore tracked.txt 2>$null | Out-Null
    & git -C $dir commit -q -m 'v1' 2>$null | Out-Null
    Set-Content -Path (Join-Path $dir 'tracked.txt') -Value 'v2' -Encoding UTF8
    & git -C $dir add tracked.txt 2>$null | Out-Null
    & git -C $dir commit -q -m 'v2' 2>$null | Out-Null
    $putBase = (& git -C $dir rev-parse 'HEAD~1' | Out-String).Trim()
    Set-Content -Path (Join-Path $dir '.stride-env-cache') -Value "TASK_ID=42`nTASK_BASE_REF=$putBase" -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
    return $dir
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: git not available — Group 10 requires it" -ForegroundColor Yellow
} else {
    # 10a: inline stdout JSON writes the full cache with TASK_BASE_REF = HEAD.
    $brA = New-GitRepo -Name 'g10-inline'
    $headA = (& git -C $brA rev-parse HEAD | Out-String).Trim()
    $claimA = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":42,"identifier":"W42","title":"Inline Task","status":"in_progress","complexity":"medium","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimA -Phase 'post' -ProjectDir $brA
    Assert-Exit "10a: inline JSON claim exits 0" 0 $r.ExitCode
    $cacheA = Get-Content -Raw -Path (Join-Path $brA '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10a: inline JSON writes the identifier" "TASK_IDENTIFIER=W42" $cacheA
    Assert-Contains "10a: inline JSON sets TASK_BASE_REF to current HEAD" "TASK_BASE_REF=$headA" $cacheA

    # 10b: a persisted-output notice pointing at a readable file containing the
    # API JSON writes the full cache from the file content.
    $brB = New-GitRepo -Name 'g10-persisted'
    $headB = (& git -C $brB rev-parse HEAD | Out-String).Trim()
    $persistDirB = Join-Path $TmpDir 'g10-persist-b'
    New-Item -ItemType Directory -Path $persistDirB -Force | Out-Null
    $persistFileB = Join-Path $persistDirB 'persisted.json'
    Set-Content -Path $persistFileB -Value '{"data":{"id":77,"identifier":"W77","title":"Persisted Task","status":"in_progress","complexity":"medium","priority":"high"}}' -Encoding UTF8 -NoNewline
    $claimB = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileB"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimB -Phase 'post' -ProjectDir $brB
    Assert-Exit "10b: persisted-file claim exits 0" 0 $r.ExitCode
    $cacheB = Get-Content -Raw -Path (Join-Path $brB '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10b: persisted file supplies the identifier" "TASK_IDENTIFIER=W77" $cacheB
    Assert-Contains "10b: persisted file path sets TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headB" $cacheB

    # 10c: garbage stdout with no persisted file refreshes only TASK_BASE_REF,
    # preserves the prior TASK_ID line, and removes the stale snapshot.
    $brC = New-GitRepo -Name 'g10-garbage'
    $headC = (& git -C $brC rev-parse HEAD | Out-String).Trim()
    Set-Content -Path (Join-Path $brC '.stride-changed-files.json') -Value '[{"path":"stale.txt","diff":"x"}]' -Encoding UTF8
    $claimC = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'this is not json at all'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimC -Phase 'post' -ProjectDir $brC
    Assert-Exit "10c: garbage-stdout claim exits 0" 0 $r.ExitCode
    $cacheC = Get-Content -Raw -Path (Join-Path $brC '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10c: garbage stdout preserves the prior TASK_ID" "TASK_ID=42" $cacheC
    Assert-Contains "10c: garbage stdout still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headC" $cacheC
    if (-not (Test-Path (Join-Path $brC '.stride-changed-files.json'))) {
        Write-Host "  PASS: 10c: base-ref-only refresh removes the stale snapshot" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 10c: stale snapshot survived the base-ref-only refresh" -ForegroundColor Red
        $script:FAIL++
    }

    # 10d: a persisted-output notice pointing at a MISSING file falls through to
    # the base-ref-only refresh (prior TASK_ID preserved, TASK_BASE_REF = HEAD).
    $brD = New-GitRepo -Name 'g10-missing-file'
    $headD = (& git -C $brD rev-parse HEAD | Out-String).Trim()
    $claimD = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $TmpDir/g10-does-not-exist.json"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimD -Phase 'post' -ProjectDir $brD
    Assert-Exit "10d: missing-persisted-file claim exits 0" 0 $r.ExitCode
    $cacheD = Get-Content -Raw -Path (Join-Path $brD '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10d: missing persisted file preserves the prior TASK_ID" "TASK_ID=42" $cacheD
    Assert-Contains "10d: missing persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headD" $cacheD

    # 10e: a non-claim post invocation (complete URL) leaves TASK_BASE_REF
    # untouched at the previously-recorded base ref.
    $brE = New-GitRepo -Name 'g10-noclaim'
    $putBaseE = (& git -C $brE rev-parse 'HEAD~1' | Out-String).Trim()
    $claimE = @{ tool_input = @{ command = 'curl -X PATCH http://127.0.0.1:1/api/tasks/42/complete' } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimE -Phase 'post' -ProjectDir $brE
    Assert-Exit "10e: complete URL exits 0" 0 $r.ExitCode
    $cacheE = Get-Content -Raw -Path (Join-Path $brE '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10e: complete URL leaves TASK_BASE_REF at the prior base ref" "TASK_BASE_REF=$putBaseE" $cacheE

    # 10f: garbage stdout in a NON-git directory (rev-parse fails) never crashes
    # the hook and writes no cache.
    $brF = Join-Path $TmpDir 'g10-nongit'
    New-Item -ItemType Directory -Path $brF -Force | Out-Null
    Set-Content -Path (Join-Path $brF '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
    $claimF = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'not json'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimF -Phase 'post' -ProjectDir $brF
    Assert-Exit "10f: garbage stdout in a non-git dir exits 0" 0 $r.ExitCode
    if (-not (Test-Path (Join-Path $brF '.stride-env-cache'))) {
        Write-Host "  PASS: 10f: no cache written when HEAD is unresolvable" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 10f: cache written despite unresolvable HEAD" -ForegroundColor Red
        $script:FAIL++
    }

    # 10g: a persisted file whose content is harness preview text (not JSON)
    # falls through to the base-ref-only refresh.
    $brG = New-GitRepo -Name 'g10-nonjson-file'
    $headG = (& git -C $brG rev-parse HEAD | Out-String).Trim()
    $persistDirG = Join-Path $TmpDir 'g10-persist-g'
    New-Item -ItemType Directory -Path $persistDirG -Force | Out-Null
    $persistFileG = Join-Path $persistDirG 'preview.txt'
    Set-Content -Path $persistFileG -Value "... (output truncated for preview) ...`nnot valid json" -Encoding UTF8
    $claimG = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileG"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimG -Phase 'post' -ProjectDir $brG
    Assert-Exit "10g: non-JSON-persisted-file claim exits 0" 0 $r.ExitCode
    $cacheG = Get-Content -Raw -Path (Join-Path $brG '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10g: non-JSON persisted file preserves the prior TASK_ID" "TASK_ID=42" $cacheG
    Assert-Contains "10g: non-JSON persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headG" $cacheG

    # 10h: garbage stdout with NO pre-existing cache creates one containing only
    # TASK_BASE_REF (no TASK_ identity lines to preserve).
    $brH = New-GitRepo -Name 'g10-absent-cache'
    Remove-Item -Force (Join-Path $brH '.stride-env-cache') -ErrorAction SilentlyContinue
    $headH = (& git -C $brH rev-parse HEAD | Out-String).Trim()
    $claimH = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'garbage'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimH -Phase 'post' -ProjectDir $brH
    Assert-Exit "10h: absent-cache claim exits 0" 0 $r.ExitCode
    $cacheH = Get-Content -Raw -Path (Join-Path $brH '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10h: absent cache is created with TASK_BASE_REF at HEAD" "TASK_BASE_REF=$headH" $cacheH
    Assert-NotContains "10h: no spurious TASK_ID line created" "TASK_ID=" $cacheH

    # 10i: a persisted-output path containing spaces is recovered intact. Guards
    # the bash/ps1 parity contract (W1086 test 13i).
    $brI = New-GitRepo -Name 'g10-spaced-path'
    $persistDirI = Join-Path $TmpDir 'g10 persist with space'
    New-Item -ItemType Directory -Path $persistDirI -Force | Out-Null
    $persistFileI = Join-Path $persistDirI 'persisted.json'
    Set-Content -Path $persistFileI -Value '{"data":{"id":88,"identifier":"W88","title":"Spaced Task","status":"in_progress","complexity":"small","priority":"low"}}' -Encoding UTF8 -NoNewline
    $claimI = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileI"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimI -Phase 'post' -ProjectDir $brI
    Assert-Exit "10i: spaced-path claim exits 0" 0 $r.ExitCode
    $cacheI = Get-Content -Raw -Path (Join-Path $brI '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10i: persisted path with spaces is recovered" "TASK_IDENTIFIER=W88" $cacheI

    # 10j: an id-only persisted payload (no {"data":...} envelope) caches its
    # identity lines instead of throwing under StrictMode and falling through.
    $brJ = New-GitRepo -Name 'g10-id-only'
    $headJ = (& git -C $brJ rev-parse HEAD | Out-String).Trim()
    $persistDirJ = Join-Path $TmpDir 'g10-persist-j'
    New-Item -ItemType Directory -Path $persistDirJ -Force | Out-Null
    $persistFileJ = Join-Path $persistDirJ 'persisted.json'
    Set-Content -Path $persistFileJ -Value '{"id":99,"identifier":"W99","title":"Id Only","status":"in_progress","complexity":"small","priority":"low"}' -Encoding UTF8 -NoNewline
    $claimJ = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileJ"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimJ -Phase 'post' -ProjectDir $brJ
    Assert-Exit "10j: id-only persisted payload claim exits 0" 0 $r.ExitCode
    $cacheJ = Get-Content -Raw -Path (Join-Path $brJ '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10j: id-only persisted payload caches the identifier" "TASK_IDENTIFIER=W99" $cacheJ
    Assert-Contains "10j: id-only persisted payload sets TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headJ" $cacheJ
}

# ============================================================
# Test Group 11: per-hook timeout enforcement (W1513)
# ============================================================
# Mirror of test-stride-hook.sh Test Group 14. PowerShell always enforces via
# WaitForExit(ms) (no external timeout utility needed), so there is no
# degradation case. Cases are behavioral (Invoke-HookScript) since the ps1
# exits on load and cannot be dot-sourced for unit tests. STRIDE_HOOK_TIMEOUT_SECS
# overrides the per-hook budget so the timeout path runs in ~1-2s.
Write-Host ""
Write-Host "=== Test Group 11: per-hook timeout enforcement (W1513) ==="

$toProj = Join-Path $TmpDir 'timeout-e2e'
New-Item -ItemType Directory -Path $toProj -Force | Out-Null
$toCompleteJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'

# 11a: a command that outlasts its (overridden 1s) budget is terminated and
# reported via the existing failed-JSON shape — exit_code 124, a self-describing
# timeout note, and (after_doing/pre) the exit-2 blocking semantic.
Set-Content -Path (Join-Path $toProj '.stride.md') -Value @'
## after_doing
```bash
sleep 5
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_SECS = '1'
$r = Invoke-HookScript -InputJson $toCompleteJson -Phase 'pre' -ProjectDir $toProj
Remove-Item Env:STRIDE_HOOK_TIMEOUT_SECS -ErrorAction SilentlyContinue
Assert-Exit "11a: timed-out after_doing blocks completion (exit 2)" 2 $r.ExitCode
Assert-Contains "11a: failed-JSON carries the timeout exit_code 124" '"exit_code":124' $r.Stdout
Assert-Contains "11a: failure names the per-hook timeout budget" "per-hook timeout budget" ($r.Stdout + $r.Stderr)

# 11b: a fast command well under the (overridden) budget still passes cleanly.
$toOkProj = Join-Path $TmpDir 'timeout-ok'
New-Item -ItemType Directory -Path $toOkProj -Force | Out-Null
Set-Content -Path (Join-Path $toOkProj '.stride.md') -Value @'
## after_doing
```bash
echo "fast_command_ran"
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_SECS = '5'
$r = Invoke-HookScript -InputJson $toCompleteJson -Phase 'pre' -ProjectDir $toOkProj
Remove-Item Env:STRIDE_HOOK_TIMEOUT_SECS -ErrorAction SilentlyContinue
Assert-Exit "11b: fast command under budget exits 0" 0 $r.ExitCode
Assert-Contains "11b: fast command ran" "fast_command_ran" $r.Stdout

# 11c: a non-numeric override is ignored — the documented default budget applies
# (after_doing = 120s), so a 2s command completes rather than being killed.
$toDefProj = Join-Path $TmpDir 'timeout-default'
New-Item -ItemType Directory -Path $toDefProj -Force | Out-Null
Set-Content -Path (Join-Path $toDefProj '.stride.md') -Value @'
## after_doing
```bash
sleep 2
echo "default_budget_ran"
```
'@ -Encoding UTF8
$env:STRIDE_HOOK_TIMEOUT_SECS = 'abc'
$r = Invoke-HookScript -InputJson $toCompleteJson -Phase 'pre' -ProjectDir $toDefProj
Remove-Item Env:STRIDE_HOOK_TIMEOUT_SECS -ErrorAction SilentlyContinue
Assert-Exit "11c: non-numeric override falls back to default budget (exit 0)" 0 $r.ExitCode
Assert-Contains "11c: default-budget command ran to completion" "default_budget_ran" $r.Stdout

# ============================================================
# Test Group 12: millisecond duration reporting (W1514)
# ============================================================
# Mirror of test-stride-hook.sh Test Group 15 (15d). The success JSON must carry
# an integer duration_ms (from Stopwatch.Elapsed.TotalMilliseconds) and no
# lingering duration_seconds field.
Write-Host ""
Write-Host "=== Test Group 12: millisecond duration reporting (W1514) ==="

$msProj = Join-Path $TmpDir 'duration-ms'
New-Item -ItemType Directory -Path $msProj -Force | Out-Null
Set-Content -Path (Join-Path $msProj '.stride.md') -Value @'
## after_doing
```bash
echo "ms_test"
```
'@ -Encoding UTF8
$msCompleteJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
$r = Invoke-HookScript -InputJson $msCompleteJson -Phase 'pre' -ProjectDir $msProj
Assert-Exit "12a: duration_ms hook exits 0" 0 $r.ExitCode
Assert-Contains "12a: success JSON carries duration_ms" '"duration_ms":' $r.Stdout
# ConvertTo-Json -Compress emits an unquoted number for an [int]; a quoted value
# would mean it was serialized as a string.
Assert-NotContains "12a: duration_ms is numeric (unquoted)" '"duration_ms":"' $r.Stdout
Assert-NotContains "12a: no lingering duration_seconds field" 'duration_seconds' $r.Stdout

# ============================================================
# Test Group 13: backslash line-continuation in the parser (W1515)
# ============================================================
# Mirror of test-stride-hook.sh Test Group 16.
Write-Host ""
Write-Host "=== Test Group 13: backslash line-continuation (W1515) ==="

$contCompleteJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'

# 13a: a command split across lines with a trailing backslash joins into ONE.
$contProj = Join-Path $TmpDir 'continuation-join'
New-Item -ItemType Directory -Path $contProj -Force | Out-Null
Set-Content -Path (Join-Path $contProj '.stride.md') -Value @'
## after_doing
```bash
echo one \
two three
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contCompleteJson -Phase 'pre' -ProjectDir $contProj
Assert-Exit "13a: continuation hook exits 0" 0 $r.ExitCode
$contObj = $null
try { $contObj = $r.Stdout | ConvertFrom-Json } catch { $contObj = $null }
if ($contObj -and @($contObj.commands_completed).Count -eq 1 -and
    @($contObj.commands_completed)[0] -eq 'echo one two three') {
    Write-Host "  PASS: 13a: continued lines collapse to a single joined command" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 13a: expected single 'echo one two three' command: $($r.Stdout)" -ForegroundColor Red
    $script:FAIL++
}

# 13b: a standalone comment after a completed command is skipped, not glued.
$contCmtProj = Join-Path $TmpDir 'continuation-comment'
New-Item -ItemType Directory -Path $contCmtProj -Force | Out-Null
Set-Content -Path (Join-Path $contCmtProj '.stride.md') -Value @'
## after_doing
```bash
echo alpha \
beta
# a standalone comment
echo gamma
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contCompleteJson -Phase 'pre' -ProjectDir $contCmtProj
$contCmtObj = $null
try { $contCmtObj = $r.Stdout | ConvertFrom-Json } catch { $contCmtObj = $null }
$contCmtCmds = @($contCmtObj.commands_completed)
if ($contCmtObj -and $contCmtCmds.Count -eq 2 -and
    $contCmtCmds[0] -eq 'echo alpha beta' -and $contCmtCmds[1] -eq 'echo gamma') {
    Write-Host "  PASS: 13b: two commands, comment skipped (not glued)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 13b: expected [echo alpha beta, echo gamma]: $($r.Stdout)" -ForegroundColor Red
    $script:FAIL++
}
Assert-NotContains "13b: comment text never entered a command" 'standalone comment' ($contCmtCmds -join '|')

# 13c: an even run of trailing backslashes is literal, not a continuation.
$contLitProj = Join-Path $TmpDir 'continuation-literal'
New-Item -ItemType Directory -Path $contLitProj -Force | Out-Null
Set-Content -Path (Join-Path $contLitProj '.stride.md') -Value @'
## after_doing
```bash
echo end\\
echo separate
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $contCompleteJson -Phase 'pre' -ProjectDir $contLitProj
$contLitObj = $null
try { $contLitObj = $r.Stdout | ConvertFrom-Json } catch { $contLitObj = $null }
if ($contLitObj -and @($contLitObj.commands_completed).Count -eq 2) {
    Write-Host "  PASS: 13c: even trailing backslashes do not continue (2 commands)" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 13c: literal backslash wrongly joined: $($r.Stdout)" -ForegroundColor Red
    $script:FAIL++
}

# ============================================================
# Test Group 14: claim-time dirty baseline guard (W1516)
# ============================================================
# Mirror of test-stride-hook.sh Test Group 17. 14a asserts the baseline is
# recorded at before_doing; 14b asserts the upload filter drops a pre-existing,
# task-untouched entry while keeping a pre-existing file the task modified and a
# brand-new task file (the PowerShell snapshot-filtering mirror lives in
# Invoke-ChangedFilesUpload, so it is exercised through a real PUT).
Write-Host ""
Write-Host "=== Test Group 14: claim-time dirty baseline guard (W1516) ==="

# 14a: before_doing records TASK_DIRTY_BASELINE (alongside TASK_BASE_REF) when
# the working tree is already dirty at claim time.
$blProj = Join-Path $TmpDir 'baseline-record'
New-Item -ItemType Directory -Path $blProj -Force | Out-Null
& git -C $blProj init -q 2>$null
& git -C $blProj config user.email 't@t' 2>$null
& git -C $blProj config user.name 't' 2>$null
Set-Content -Path (Join-Path $blProj '.gitignore') -Value ".stride.md`n.stride-env-cache`n.stride-changed-files.json`n.stride-diff-upload-state" -Encoding UTF8
Set-Content -Path (Join-Path $blProj 'committed.txt') -Value 'committed' -Encoding UTF8
& git -C $blProj add -A 2>$null
& git -C $blProj commit -q -m init 2>$null
# Pre-existing dirty edits before the claim.
Set-Content -Path (Join-Path $blProj 'committed.txt') -Value 'pre-existing edit' -Encoding UTF8
Set-Content -Path (Join-Path $blProj 'pre_new.txt') -Value 'pre-existing untracked' -Encoding UTF8
Set-Content -Path (Join-Path $blProj '.stride.md') -Value @'
## before_doing
```bash
echo "before_doing_ran"
```
'@ -Encoding UTF8
$blClaim = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":778,\"identifier\":\"W778\",\"title\":\"BL\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}"}}'
$r = Invoke-HookScript -InputJson $blClaim -Phase 'post' -ProjectDir $blProj
Assert-Exit "14a: baseline claim exits 0" 0 $r.ExitCode
$blCache = Get-Content -Raw -Path (Join-Path $blProj '.stride-env-cache') -ErrorAction SilentlyContinue
Assert-Contains "14a: env cache records TASK_DIRTY_BASELINE" 'TASK_DIRTY_BASELINE=' $blCache
Assert-Contains "14a: env cache still records TASK_BASE_REF" 'TASK_BASE_REF=' $blCache

# 14b: the upload filter drops a pre-existing, unchanged entry but keeps a
# pre-existing file the task modified and a new task file. Exercised via a real
# PUT captured by a local HttpListener.
$blFiltProj = Join-Path $TmpDir 'baseline-filter'
New-Item -ItemType Directory -Path $blFiltProj -Force | Out-Null
Set-Content -Path (Join-Path $blFiltProj 'pre_unchanged.txt') -Value 'U1' -Encoding UTF8 -NoNewline
Set-Content -Path (Join-Path $blFiltProj 'pre_modified.txt') -Value 'M1' -Encoding UTF8 -NoNewline
Set-Content -Path (Join-Path $blFiltProj 'task_new.txt') -Value 'T1' -Encoding UTF8 -NoNewline
# Claim-time hashes (pre_modified still holds its claim-time content M1).
$hashU = (& git -C $blFiltProj hash-object pre_unchanged.txt | Out-String).Trim()
$hashM = (& git -C $blFiltProj hash-object pre_modified.txt | Out-String).Trim()
$blText = "$hashU`tpre_unchanged.txt`n$hashM`tpre_modified.txt"
$blFiltB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($blText))
# Task edits pre_modified.txt further (content now differs from the baseline).
Set-Content -Path (Join-Path $blFiltProj 'pre_modified.txt') -Value 'M2-task-edit' -Encoding UTF8 -NoNewline
Set-Content -Path (Join-Path $blFiltProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $blFiltProj '.stride-changed-files.json') `
    -Value '[{"path":"pre_unchanged.txt","diff":"d1"},{"path":"pre_modified.txt","diff":"d2"},{"path":"task_new.txt","diff":"d3"}]' -Encoding UTF8
Set-Content -Path (Join-Path $blFiltProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc`nTASK_DIRTY_BASELINE=$blFiltB64" -Encoding UTF8

$blPort = 18884
$blFixture = Join-Path $TmpDir 'baseline-put-fixture.json'
if (Test-Path $blFixture) { Remove-Item -Force $blFixture }
$blListenerJob = Start-Job -ArgumentList $blPort, $blFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
        @{ Body = $reader.ReadToEnd() } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $ctx.Response.StatusCode = 200
        $ctx.Response.OutputStream.Close()
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
try {
    $null = Wait-ForListener -Port $blPort
    $blCmd = "curl -X PATCH http://localhost:$blPort/api/tasks/99/complete -H `"Authorization: Bearer tok`""
    $blJson = @{ tool_input = @{ command = $blCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $blJson -Phase 'pre' -ProjectDir $blFiltProj
    Assert-Exit "14b: hook exits 0 after filtered PUT" 0 $r.ExitCode
    Wait-Job $blListenerJob -Timeout 8 | Out-Null
    Remove-Job $blListenerJob -Force -ErrorAction SilentlyContinue
    if (Test-Path $blFixture) {
        $rec = Get-Content -Raw -Path $blFixture | ConvertFrom-Json
        $env = $rec.Body | ConvertFrom-Json
        $paths = @()
        try {
            $decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($env.changed_files.data))
            $paths = @(($decoded | ConvertFrom-Json) | ForEach-Object { $_.path })
        } catch { $paths = @() }
        if ($paths -notcontains 'pre_unchanged.txt') {
            Write-Host "  PASS: 14b: pre-existing unchanged entry filtered from the PUT" -ForegroundColor Green; $script:PASS++
        } else {
            Write-Host "  FAIL: 14b: pre-existing unchanged entry leaked: $($paths -join ',')" -ForegroundColor Red; $script:FAIL++
        }
        if ($paths -contains 'pre_modified.txt') {
            Write-Host "  PASS: 14b: task-modified pre-existing entry kept" -ForegroundColor Green; $script:PASS++
        } else {
            Write-Host "  FAIL: 14b: task-modified entry wrongly filtered: $($paths -join ',')" -ForegroundColor Red; $script:FAIL++
        }
        if ($paths -contains 'task_new.txt') {
            Write-Host "  PASS: 14b: new task entry kept" -ForegroundColor Green; $script:PASS++
        } else {
            Write-Host "  FAIL: 14b: new task entry missing: $($paths -join ',')" -ForegroundColor Red; $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 14b: PUT did not arrive at listener" -ForegroundColor Red; $script:FAIL++
    }
} finally {
    if ($blListenerJob -and $blListenerJob.State -eq 'Running') {
        Stop-Job $blListenerJob -ErrorAction SilentlyContinue
        Remove-Job $blListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Test Group 15: canonical response file + D119 fresh call
# (mirrors test-stride-hook.sh D118/W1609 Group 8 + D119 Group 18)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 15: canonical file + D119 fresh call ==="

# Listener that answers GET /api/tasks/:id/after_goal_status with a JSON body
# and logs the hit to a fixture file. $Armed toggles after_goal_armed.
function Start-AfterGoalStatusListener {
    param([int]$Port, [string]$Fixture, [bool]$Armed = $true)
    Start-Job -ArgumentList $Port, $Fixture, $Armed -ScriptBlock {
        param($Port, $Fixture, $Armed)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            # Async accept with a bounded wait so the de-dup case (no request
            # ever arrives) self-terminates within the timeout instead of
            # blocking GetContext() forever — otherwise Stop-Job/Wait-Job on the
            # caller would hang.
            $ctxTask = $l.GetContextAsync()
            if (-not $ctxTask.Wait(9000)) { return }
            $ctx = $ctxTask.Result
            $req = $ctx.Request
            @{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath } |
                ConvertTo-Json -Compress | Add-Content -Path $Fixture -Encoding UTF8
            if ($Armed) {
                $bodyStr = '{"after_goal_armed":true,"goal_id":55,"goal_identifier":"G7","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G7","GOAL_TITLE":"Goal Seven","HOOK_NAME":"after_goal"}}'
            } else {
                $bodyStr = '{"after_goal_armed":false,"goal_id":null,"goal_identifier":null,"env":{}}'
            }
            $buf = [System.Text.Encoding]::UTF8.GetBytes($bodyStr)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
            $ctx.Response.OutputStream.Close()
        } catch {
            # Listener tear-down errors are ignored.
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
}

# Project whose ## after_goal echoes GOAL_IDENTIFIER; env cache pre-seeds TASK_ID.
function New-D119Project {
    param([string]$Suffix)
    $dir = Join-Path $TmpDir "d119-$Suffix"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Set-Content -Path (Join-Path $dir '.stride.md') -Value @'
## after_goal
```bash
echo "after_goal_ran for $GOAL_IDENTIFIER"
```
'@ -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride-env-cache') -Value 'TASK_ID=42' -Encoding UTF8
    return $dir
}

# 15a (D118): a truncated /complete stdout with a present canonical response file
# carrying after_goal -> the section runs from the file (fast path), no fresh call.
$d15aProj = New-D119Project -Suffix 'file-fastpath'
New-Item -ItemType Directory -Path (Join-Path $d15aProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $d15aProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":42},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G9"}}]}' -Encoding UTF8 -NoNewline
$d15aInput = @{
    tool_input    = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/42/complete -H "Authorization: Bearer tok"' }
    tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15aInput -Phase 'post' -ProjectDir $d15aProj
Assert-Exit "15a: truncated stdout + canonical file exits 0" 0 $r.ExitCode
Assert-Contains "15a: after_goal runs from the canonical file (G9)" "after_goal_ran for G9" $r.Stdout

# 15b (W1609): a claim with truncated stdout + present canonical file recovers
# the full task JSON from the file into the env cache (TASK_IDENTIFIER).
$d15bProj = Join-Path $TmpDir 'd119-claim-file'
New-Item -ItemType Directory -Path $d15bProj -Force | Out-Null
Set-Content -Path (Join-Path $d15bProj '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
New-Item -ItemType Directory -Path (Join-Path $d15bProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $d15bProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":609,"identifier":"W609","title":"File Task","status":"in_progress","complexity":"medium","priority":"high"}}' -Encoding UTF8 -NoNewline
$d15bInput = @{
    tool_input    = @{ command = 'curl -X POST https://stridelikeaboss.com/api/tasks/claim' }
    tool_response = @{ stdout = '{"data":{"id":609,"identif' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15bInput -Phase 'post' -ProjectDir $d15bProj
$d15bCache = ''
if (Test-Path (Join-Path $d15bProj '.stride-env-cache')) {
    $d15bCache = Get-Content (Join-Path $d15bProj '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "15b: truncated claim recovers identifier from the canonical file" "TASK_IDENTIFIER=W609" $d15bCache

# 15c (W1609): a valid claim stdout is captured to the canonical response file.
$d15cProj = Join-Path $TmpDir 'd119-capture'
New-Item -ItemType Directory -Path $d15cProj -Force | Out-Null
Set-Content -Path (Join-Path $d15cProj '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
$d15cInput = @{
    tool_input    = @{ command = 'curl -X POST https://stridelikeaboss.com/api/tasks/claim' }
    tool_response = @{ stdout = '{"data":{"id":610,"identifier":"W610","title":"Cap","status":"in_progress","complexity":"small","priority":"low"}}' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15cInput -Phase 'post' -ProjectDir $d15cProj
$d15cFile = ''
if (Test-Path (Join-Path $d15cProj '.stride/.last-api-response.json')) {
    $d15cFile = Get-Content (Join-Path $d15cProj '.stride/.last-api-response.json') -Raw -Encoding UTF8
}
Assert-Contains "15c: valid claim stdout captured to the canonical file" '"identifier":"W610"' $d15cFile

# 15d (D119): truncated stdout + NO file + armed endpoint -> fresh call runs after_goal.
$d15dPort = 18901
$d15dFixture = Join-Path $TmpDir 'd119-armed-fixture.txt'
$d15dProj = New-D119Project -Suffix 'fresh-armed'
$d15dJob = Start-AfterGoalStatusListener -Port $d15dPort -Fixture $d15dFixture -Armed $true
try {
    $null = Wait-ForListener -Port $d15dPort
    $d15dInput = @{
        tool_input    = @{ command = "curl -X PATCH http://localhost:$d15dPort/api/tasks/42/complete -H `"Authorization: Bearer tok`"" }
        tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d15dInput -Phase 'post' -ProjectDir $d15dProj
    Assert-Exit "15d: hook-initiated after_goal exits 0" 0 $r.ExitCode
    Assert-Contains "15d: fresh call ran after_goal with endpoint GOAL_IDENTIFIER" "after_goal_ran for G7" $r.Stdout
} finally {
    Wait-Job $d15dJob -Timeout 8 | Out-Null
    Remove-Job $d15dJob -Force -ErrorAction SilentlyContinue
}
$d15dHit = Get-Content -Raw -Path $d15dFixture -ErrorAction SilentlyContinue
Assert-Contains "15d: the after_goal_status endpoint was called" "after_goal_status" ([string]$d15dHit)

# 15e (D119): armed=false -> after_goal does NOT run.
$d15ePort = 18902
$d15eFixture = Join-Path $TmpDir 'd119-notarmed-fixture.txt'
$d15eProj = New-D119Project -Suffix 'fresh-notarmed'
$d15eJob = Start-AfterGoalStatusListener -Port $d15ePort -Fixture $d15eFixture -Armed $false
try {
    $null = Wait-ForListener -Port $d15ePort
    $d15eInput = @{
        tool_input    = @{ command = "curl -X PATCH http://localhost:$d15ePort/api/tasks/42/complete -H `"Authorization: Bearer tok`"" }
        tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d15eInput -Phase 'post' -ProjectDir $d15eProj
    Assert-Exit "15e: armed=false exits 0" 0 $r.ExitCode
    Assert-NotContains "15e: armed=false does not run after_goal" "after_goal_ran" $r.Stdout
} finally {
    Wait-Job $d15eJob -Timeout 8 | Out-Null
    Remove-Job $d15eJob -Force -ErrorAction SilentlyContinue
}

# 15f (D119 de-dup): a present canonical file (fast path) runs the section once
# and the fresh endpoint is NOT called.
$d15fPort = 18903
$d15fFixture = Join-Path $TmpDir 'd119-dedup-fixture.txt'
$d15fProj = New-D119Project -Suffix 'dedup'
New-Item -ItemType Directory -Path (Join-Path $d15fProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $d15fProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":42},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G9"}}]}' -Encoding UTF8 -NoNewline
$d15fJob = Start-AfterGoalStatusListener -Port $d15fPort -Fixture $d15fFixture -Armed $true
try {
    $null = Wait-ForListener -Port $d15fPort
    $d15fInput = @{
        tool_input    = @{ command = "curl -X PATCH http://localhost:$d15fPort/api/tasks/42/complete -H `"Authorization: Bearer tok`"" }
        tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d15fInput -Phase 'post' -ProjectDir $d15fProj
    Assert-Contains "15f: fast path runs after_goal from the file (G9)" "after_goal_ran for G9" $r.Stdout
    $d15fRuns = ([regex]::Matches($r.Stdout, 'ran for G9')).Count
    Assert-Eq "15f: after_goal ran exactly once (de-dup)" 1 $d15fRuns
} finally {
    # De-dup: the endpoint is never hit, so the listener self-terminates via its
    # bounded async wait; Wait-Job then completes without hanging.
    Wait-Job $d15fJob -Timeout 11 | Out-Null
    Remove-Job $d15fJob -Force -ErrorAction SilentlyContinue
}
$d15fHit = Get-Content -Raw -Path $d15fFixture -ErrorAction SilentlyContinue
Assert-NotContains "15f: fast path short-circuits the fresh call (endpoint not hit)" "after_goal_status" ([string]$d15fHit)

# 15g (D119): unreachable endpoint -> clean no-op, exit 0, section not run.
$d15gProj = New-D119Project -Suffix 'unreachable'
$d15gInput = @{
    tool_input    = @{ command = 'curl -X PATCH http://localhost:18904/api/tasks/42/complete -H "Authorization: Bearer tok"' }
    tool_response = @{ stdout = '{"data":{"id":42},"hoo' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $d15gInput -Phase 'post' -ProjectDir $d15gProj
Assert-Exit "15g: unreachable endpoint still exits 0" 0 $r.ExitCode
Assert-NotContains "15g: unreachable endpoint does not run after_goal" "after_goal_ran" $r.Stdout

# ============================================================
# Test Group 16: after_goal reliability under truncation (W1612)
# ============================================================
# PowerShell parity of test-stride-hook.sh Group 19: under a truncated
# tool_response.stdout, prove after_goal is detected, GOAL_* is exported, and
# ## after_goal runs via the canonical response file — plus the parent_id
# fallback and missing-section edge cases, and a no-file no-false-positive
# control. (The fresh-call path itself is covered by Group 15.)
Write-Host ""
Write-Host "=== Test Group 16: after_goal reliability under truncation (W1612) ==="

# A /complete input whose stdout is truncated mid-JSON, so detection MUST come
# from the canonical response file.
$w16Trunc = @{
    tool_input    = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' }
    tool_response = @{ stdout = '{"data":{"id":99},"hoo' }
} | ConvertTo-Json -Compress

# 16a: truncated stdout + present canonical file with a full after_goal entry ->
# section runs, GOAL_* reaches the section AND the env cache (reliability proof).
$w16aProj = Join-Path $TmpDir 'w1612-fastpath'
New-Item -ItemType Directory -Path (Join-Path $w16aProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16aProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER] title=[$GOAL_TITLE]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16aProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":55},"hooks":[{"name":"before_review"},{"name":"after_goal","env":{"GOAL_ID":"55","GOAL_IDENTIFIER":"G55","GOAL_TITLE":"Goal 55"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16aProj
Assert-Exit "16a: truncated /complete with a present file exits 0" 0 $r.ExitCode
Assert-Contains "16a: ## after_goal ran with GOAL_IDENTIFIER from the file" "ident=[G55]" $r.Stdout
Assert-Contains "16a: GOAL_TITLE exported to the section" "title=[Goal 55]" $r.Stdout
$w16aCache = ''
if (Test-Path (Join-Path $w16aProj '.stride-env-cache')) {
    $w16aCache = Get-Content (Join-Path $w16aProj '.stride-env-cache') -Raw -Encoding UTF8
}
Assert-Contains "16a: env cache carries GOAL_ID for the follow-up PATCH" "GOAL_ID=55" $w16aCache

# 16b: truncated stdout + present file whose after_goal env OMITS GOAL_ID but
# data.parent_id is set -> parent-id fallback exports GOAL_ID under truncation.
$w16bProj = Join-Path $TmpDir 'w1612-parentid'
New-Item -ItemType Directory -Path (Join-Path $w16bProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16bProj '.stride.md') -Value @'
## after_goal
```bash
echo "goal=[$GOAL_ID] ident=[$GOAL_IDENTIFIER]"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16bProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"parent_id":77},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G77"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16bProj
Assert-Contains "16b: GOAL_ID falls back to data.parent_id under truncation" "goal=[77]" $r.Stdout
Assert-Contains "16b: GOAL_IDENTIFIER still exported from the file" "ident=[G77]" $r.Stdout

# 16c: truncated stdout + present file WITH an after_goal entry, but the
# ## after_goal section is MISSING -> clean no-op (exit 0, no after_goal JSON).
$w16cProj = Join-Path $TmpDir 'w1612-missing'
New-Item -ItemType Directory -Path (Join-Path $w16cProj '.stride') -Force | Out-Null
Set-Content -Path (Join-Path $w16cProj '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16cProj '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99},"hooks":[{"name":"after_goal","env":{"GOAL_IDENTIFIER":"G88"}}]}' -Encoding UTF8 -NoNewline
$r = Invoke-HookScript -InputJson $w16Trunc -Phase 'post' -ProjectDir $w16cProj
Assert-Exit "16c: missing ## after_goal under truncation exits 0" 0 $r.ExitCode
Assert-NotContains "16c: missing ## after_goal emits no after_goal JSON" '"hook":"after_goal"' $r.Stdout

# 16d: no-file control — truncated stdout, NO canonical file, and no reachable
# after_goal_status endpoint -> the section must NOT run (no false positive).
$w16dProj = Join-Path $TmpDir 'w1612-nofile'
New-Item -ItemType Directory -Path $w16dProj -Force | Out-Null
Set-Content -Path (Join-Path $w16dProj '.stride.md') -Value @'
## after_goal
```bash
echo "after_goal_ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $w16dProj '.stride-env-cache') -Value 'TASK_ID=99' -Encoding UTF8
$w16dInput = @{
    tool_input    = @{ command = 'curl -X PATCH http://localhost:19099/api/tasks/99/complete -H "Authorization: Bearer tok"' }
    tool_response = @{ stdout = '{"data":{"id":99},"hoo' }
} | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $w16dInput -Phase 'post' -ProjectDir $w16dProj
Assert-Exit "16d: no-file + truncated + unreachable exits 0" 0 $r.ExitCode
Assert-NotContains "16d: no file + no endpoint does not run ## after_goal" "after_goal_ran" $r.Stdout

# ============================================================
# Test Group 17: D142 — post-pull TASK_BASE_REF + committed-range override
# (ports the reference plugin's Test Group 17 to copilot's base64
# TASK_DIRTY_BASELINE transport)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 17: D142 post-pull TASK_BASE_REF + committed-range override ==="

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: git not available — Group 17 requires it" -ForegroundColor Yellow
} else {
    # 17a: the claim-time refresh records the POST-pull branch point. A bare
    # origin and a second clone simulate another computer whose completed task
    # arrives via the ## before_doing pull (the D132/W1678 incident). copilot
    # writes the base in Invoke-FinalizeBeforeDoing AFTER the section runs, so
    # the post-pull HEAD lands in the env cache even though the claim block
    # itself now writes identity only.
    $d142Root = Join-Path $TmpDir 'g17-d142'
    New-Item -ItemType Directory -Path $d142Root -Force | Out-Null
    & git init -q --bare (Join-Path $d142Root 'origin.git') 2>$null | Out-Null
    # Point the bare HEAD at main so both clones check out the same branch
    # regardless of the host's init.defaultBranch.
    & git -C (Join-Path $d142Root 'origin.git') symbolic-ref HEAD refs/heads/main 2>$null | Out-Null
    $cloneA = Join-Path $d142Root 'cloneA'
    & git clone -q (Join-Path $d142Root 'origin.git') $cloneA 2>$null | Out-Null
    & git -C $cloneA config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $cloneA config user.name 'Test' 2>$null | Out-Null
    & git -C $cloneA config commit.gpgsign false 2>$null | Out-Null
    & git -C $cloneA checkout -q -b main 2>$null | Out-Null
    Set-Content -Path (Join-Path $cloneA '.gitignore') `
        -Value ".stride.md`n.stride-env-cache`n.stride-changed-files.json`n.stride-diff-upload-state" -Encoding UTF8
    Set-Content -Path (Join-Path $cloneA 'base.txt') -Value 'base' -Encoding UTF8
    & git -C $cloneA add .gitignore base.txt 2>$null | Out-Null
    & git -C $cloneA commit -q -m 'base' 2>$null | Out-Null
    & git -C $cloneA push -q origin main 2>$null | Out-Null
    $cloneB = Join-Path $d142Root 'cloneB'
    & git clone -q (Join-Path $d142Root 'origin.git') $cloneB 2>$null | Out-Null
    & git -C $cloneB config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $cloneB config user.name 'Test' 2>$null | Out-Null
    & git -C $cloneB config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $cloneB 'w1678.txt') -Value 'other' -Encoding UTF8
    & git -C $cloneB add w1678.txt 2>$null | Out-Null
    & git -C $cloneB commit -q -m 'other clone task' 2>$null | Out-Null
    & git -C $cloneB push -q origin main 2>$null | Out-Null

    $prePull = (& git -C $cloneA rev-parse HEAD | Out-String).Trim()
    Set-Content -Path (Join-Path $cloneA '.stride.md') -Value @'
## before_doing
```bash
git pull -q origin main
```
'@ -Encoding UTF8
    # Stale cache from a "previous session" — must be fully replaced.
    Set-Content -Path (Join-Path $cloneA '.stride-env-cache') `
        -Value "TASK_ID=OLD1`nTASK_BASE_REF=1111111111111111111111111111111111111111" -Encoding UTF8
    $d142Claim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":142,"identifier":"D142","title":"Cross clone","status":"in_progress","complexity":"medium","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d142Claim -Phase 'post' -ProjectDir $cloneA
    Assert-Exit "17a: cross-clone claim exits 0" 0 $r.ExitCode
    $postPull = (& git -C $cloneA rev-parse HEAD | Out-String).Trim()
    if ($prePull -eq $postPull) {
        Write-Host "  FAIL: 17a fixture vacuous — the before_doing pull did not move HEAD" -ForegroundColor Red
        $script:FAIL++
    } else {
        Write-Host "  PASS: 17a fixture: the before_doing pull moved HEAD (discriminating power)" -ForegroundColor Green
        $script:PASS++
    }
    $d142Cache = Get-Content -Raw -Path (Join-Path $cloneA '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "17a: claim records the POST-pull branch point as TASK_BASE_REF" "TASK_BASE_REF=$postPull" $d142Cache
    Assert-NotContains "17a: the stale prior-session TASK_BASE_REF was replaced" "1111111111111111111111111111111111111111" $d142Cache

    # 17b: committed-range override — a baseline entry whose path the task's
    # commits contain is task work and must survive the upload filter (D137
    # silently dropped committed files whose content matched the claim-time
    # hash). copilot carries the baseline as the base64 TASK_DIRTY_BASELINE
    # env-cache line rather than a .stride-dirty-baseline file.
    $crProj = New-GitRepo -Name 'g17-committed'
    $crBase = (& git -C $crProj rev-parse HEAD | Out-String).Trim()
    # Pre-claim dirt, then the auto-commit commits it as the task's work.
    Add-Content -Path (Join-Path $crProj 'tracked.txt') -Value 'task edit present at claim' -Encoding UTF8
    $crHash = (& git -C $crProj hash-object -- 'tracked.txt' | Out-String).Trim()
    $crBlLine = "$crHash`ttracked.txt"
    $crBlB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($crBlLine))
    & git -C $crProj add tracked.txt 2>$null | Out-Null
    & git -C $crProj commit -q -m 'task auto-commit' 2>$null | Out-Null
    Set-Content -Path (Join-Path $crProj '.stride-changed-files.json') `
        -Value '[{"path":"tracked.txt","diff":"task work"}]' -Encoding UTF8
    Set-Content -Path (Join-Path $crProj '.stride-env-cache') `
        -Value "TASK_ID=99`nTASK_BASE_REF=$crBase`nTASK_DIRTY_BASELINE=$crBlB64" -Encoding UTF8
    Set-Content -Path (Join-Path $crProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8

    $crPort = 18894
    $crFixture = Join-Path $TmpDir 'd142-put-fixture.json'
    if (Test-Path $crFixture) { Remove-Item -Force $crFixture }
    $crListenerJob = Start-Job -ArgumentList $crPort, $crFixture -ScriptBlock {
        param($Port, $Fixture)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            $ctx = $l.GetContext()
            $req = $ctx.Request
            $reader = [System.IO.StreamReader]::new($req.InputStream)
            $body = $reader.ReadToEnd()
            @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
            $resp = $ctx.Response
            $resp.StatusCode = 200
            $resp.OutputStream.Close()
        } catch {
            # Listener tear-down errors are ignored.
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
    try {
        $null = Wait-ForListener -Port $crPort
        $crCmd = "curl -X PATCH http://localhost:$crPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_cr`""
        $crJson = @{ tool_input = @{ command = $crCmd } } | ConvertTo-Json -Compress
        $r = Invoke-HookScript -InputJson $crJson -Phase 'pre' -ProjectDir $crProj
        Assert-Exit "17b: hook exits 0 after the committed-range PUT" 0 $r.ExitCode

        Wait-Job $crListenerJob -Timeout 8 | Out-Null
        Remove-Job $crListenerJob -Force -ErrorAction SilentlyContinue

        if (Test-Path $crFixture) {
            $record = Get-Content -Raw -Path $crFixture | ConvertFrom-Json
            $parsedBody = $record.Body | ConvertFrom-Json
            $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
            $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
            $entries = @($decodedText | ConvertFrom-Json)
            $paths = @($entries | ForEach-Object { $_.path })
            if ($paths -contains 'tracked.txt') {
                Write-Host "  PASS: 17b: committed task work survives the baseline filter" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 17b: committed task work was dropped, got: $($paths -join ', ')" -ForegroundColor Red
                $script:FAIL++
            }
        } else {
            Write-Host "  FAIL: 17b: no PUT recorded by the listener" -ForegroundColor Red
            $script:FAIL++
        }
    } finally {
        Remove-Job $crListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Test Group 18: W2147 loop state recorded on completion
# ============================================================
# PowerShell parity of test-stride-hook.sh Group 21, case for case. The Stop
# gate cannot refuse an action it has no evidence for; these cover the file
# that becomes that evidence. Every completed_at assertion reads the RAW file
# text rather than a ConvertFrom-Json result, because PowerShell's parser
# coerces an ISO-8601 string to [DateTime] — a parsed assertion would test the
# parser instead of the writer.
Write-Host ""
Write-Host "=== Test Group 18: W2147 loop state on completion (ps1) ==="

$G18Url = 'https://www.stridelikeaboss.com'
$G18State = '.stride/.loop-state.json'
$G18CompleteCmd = "curl -sS -X PATCH $G18Url/api/tasks/99/complete -d @payload.json | tee r.json"
$G18ClaimCmd = "curl -sS -X POST $G18Url/api/tasks/claim -d @c.json | tee r.json"
$G18Ok = '{"data":{"id":99,"identifier":"W2147","needs_review":false},"hooks":[{"name":"before_review"}]}'

# session_id is added ONLY when non-empty, so the "no session id" case
# genuinely omits the key rather than carrying an empty one.
function New-G18Input {
    param([string]$SessionId, [string]$Command, [string]$Stdout)
    $o = [ordered]@{}
    if ($SessionId) { $o['session_id'] = $SessionId }
    $o['tool_input'] = @{ command = $Command }
    $o['tool_response'] = @{ stdout = $Stdout }
    return ($o | ConvertTo-Json -Compress -Depth 6)
}

function New-G18Project {
    param([string]$Name)
    $d = Join-Path $TmpDir "w2147-$Name"
    if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path (Join-Path $d '.stride') -Force | Out-Null
    Set-Content -Path (Join-Path $d '.stride.md') -Value @'
## before_doing
```bash
```

## before_review
```bash
```
'@ -Encoding UTF8
    return $d
}

function Get-G18Raw {
    param([string]$Dir)
    $f = Join-Path $Dir $G18State
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return '' }
    return (Get-Content -LiteralPath $f -Raw)
}

function Get-G18Field {
    param([string]$Dir, [string]$Name)
    $raw = Get-G18Raw -Dir $Dir
    if (-not $raw) { return '' }
    try { $o = $raw | ConvertFrom-Json } catch { return '' }
    if ($null -eq $o -or $o.PSObject.Properties.Name -notcontains $Name) { return '' }
    return [string]$o.$Name
}

function Test-G18StateExists {
    param([string]$Dir)
    return (Test-Path -LiteralPath (Join-Path $Dir $G18State) -PathType Leaf)
}

# 18a: a successful completion writes the file with the right identifier.
$g18a = New-G18Project 'a'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 'sess-abc' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18a
Assert-Eq "18a: a successful completion records the identifier" "W2147" (Get-G18Field -Dir $g18a -Name 'identifier')
Assert-Eq "18a: it records needs_review from the response" "False" (Get-G18Field -Dir $g18a -Name 'needs_review')
Assert-Eq "18a: it records the session id" "sess-abc" (Get-G18Field -Dir $g18a -Name 'session_id')
$g18aRaw = Get-G18Raw -Dir $g18a
if ($g18aRaw -cmatch '"completed_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"') {
    Write-Host "  PASS: 18a: completed_at is an ISO8601 Z timestamp in the raw file" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 18a: completed_at is not an ISO8601 Z timestamp, raw: $g18aRaw" -ForegroundColor Red
    $script:FAIL++
}

# 18b: needs_review=true is recorded VERBATIM, and as a JSON boolean literal
# rather than the string "True" that an uncast ConvertTo-Json would emit. The
# raw-text assertion is what pins both the boolean type and the compact
# separators the bash half's `jq -nc` produces.
$g18b = New-G18Project 'b'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"data":{"id":99,"identifier":"W555","needs_review":true},"hooks":[{"name":"before_review"}]}') `
    -Phase 'post' -ProjectDir $g18b
Assert-Contains "18b: needs_review is the boolean literal true, compactly separated" '"needs_review":true' (Get-G18Raw -Dir $g18b)
Assert-NotContains "18b: needs_review is never the string True" '"needs_review":"True"' (Get-G18Raw -Dir $g18b)

# 18c: the session id falls back to CLAUDE_SESSION_ID when the input omits it.
$g18c = New-G18Project 'c'
$g18SavedSid = $env:CLAUDE_SESSION_ID
try {
    $env:CLAUDE_SESSION_ID = 'env-sess'
    $null = Invoke-HookScript -InputJson (New-G18Input -SessionId '' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18c
    Assert-Eq "18c: the session id falls back to CLAUDE_SESSION_ID" "env-sess" (Get-G18Field -Dir $g18c -Name 'session_id')

    # 18d: with no session id anywhere it degrades to "unknown" rather than
    # dropping the record. This is the ORDINARY case on this runtime: Copilot's
    # documented hook payload carries no session field, so the
    # attempt-then-degrade chain exists to keep the halves identical rather
    # than because a session id is expected today.
    $g18d = New-G18Project 'd'
    $env:CLAUDE_SESSION_ID = ''
    $null = Invoke-HookScript -InputJson (New-G18Input -SessionId '' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18d
    Assert-Eq "18d: an absent session id degrades to unknown" "unknown" (Get-G18Field -Dir $g18d -Name 'session_id')
} finally {
    if ($g18SavedSid) { $env:CLAUDE_SESSION_ID = $g18SavedSid } else { $env:CLAUDE_SESSION_ID = '' }
}

# 18e: a session id that is not identifier-shaped is refused, not sanitised.
$g18e = New-G18Project 'e'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 'not a/session id' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18e
Assert-Eq "18e: a non-identifier-shaped session id degrades to unknown" "unknown" (Get-G18Field -Dir $g18e -Name 'session_id')

# 18f: a 422 does NOT write the file. Every non-success body the API emits
# lacks `data`, which is the discriminator. Under Set-StrictMode -Version
# Latest the naive property read this replaces would be a TERMINATING error,
# turning "record nothing" into "fail the completion".
$g18f = New-G18Project 'f'
$g18fRes = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"errors":{"completion_summary":["can''t be blank"]}}') -Phase 'post' -ProjectDir $g18f
Assert-Exit "18f: a 422 completion does not fail the hook" 0 $g18fRes.ExitCode
if (Test-G18StateExists -Dir $g18f) {
    Write-Host "  FAIL: 18f: a 422 completion must not write the loop state" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18f: a 422 completion does not write the loop state" -ForegroundColor Green
    $script:PASS++
}

# 18g: THE REGRESSION GUARD. Get-ResponsePayload is canonical-file-first (D118)
# and .stride/.last-api-response.json survives across calls, so a build on it as
# the Tier-1 source would resolve the previous CLAIM payload here — which
# carries both fields — and record a completion that never happened. A naive
# implementation passes 18f and fails this.
$g18g = New-G18Project 'g'
Set-Content -Path (Join-Path $g18g '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"identifier":"W9999","needs_review":true},"hook":{"name":"before_doing"}}' -Encoding UTF8 -NoNewline
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"errors":{"base":["unprocessable"]}, TRUNCA') -Phase 'post' -ProjectDir $g18g
if (Test-G18StateExists -Dir $g18g) {
    Write-Host "  FAIL: 18g: a truncated 422 must not inherit the previous claim's payload, wrote: $(Get-G18Raw -Dir $g18g)" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18g: a truncated 422 does not inherit the previous claim's payload" -ForegroundColor Green
    $script:PASS++
}

# 18h: the other side of 18g — a harness-truncated SUCCESS still records, via
# the canonical snapshot, but only because it demonstrably belongs to THIS
# completion (hooks is an array, and the task id matches the routed id).
$g18h = New-G18Project 'h'
Set-Content -Path (Join-Path $g18h '.stride/.last-api-response.json') `
    -Value '{"data":{"id":99,"identifier":"W777","needs_review":false},"hooks":[{"name":"before_review"}]}' -Encoding UTF8 -NoNewline
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"data":{"identifier":"W7 TRUNCA') -Phase 'post' -ProjectDir $g18h
Assert-Eq "18h: a truncated success recovers from the matching snapshot" "W777" (Get-G18Field -Dir $g18h -Name 'identifier')

# 18i: and that recovery refuses a snapshot belonging to a DIFFERENT task.
$g18i = New-G18Project 'i'
Set-Content -Path (Join-Path $g18i '.stride/.last-api-response.json') `
    -Value '{"data":{"id":12345,"identifier":"W_OTHER","needs_review":false},"hooks":[{"name":"before_review"}]}' -Encoding UTF8 -NoNewline
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"data": TRUNCA') -Phase 'post' -ProjectDir $g18i
if (Test-G18StateExists -Dir $g18i) {
    Write-Host "  FAIL: 18i: recovery must refuse a snapshot for another task id" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18i: recovery refuses a snapshot for another task id" -ForegroundColor Green
    $script:PASS++
}

# 18j: a claim clears a stale record.
$g18j = New-G18Project 'j'
Set-Content -Path (Join-Path $g18j $G18State) `
    -Value '{"identifier":"W_OLD","needs_review":false,"completed_at":"2020-01-01T00:00:00Z","session_id":"old"}' -Encoding UTF8 -NoNewline
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18ClaimCmd `
    -Stdout '{"data":{"id":99,"identifier":"W1"},"hook":{"name":"before_doing"}}') -Phase 'post' -ProjectDir $g18j
if (Test-G18StateExists -Dir $g18j) {
    Write-Host "  FAIL: 18j: a claim must clear the previous completion's loop state" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18j: a claim clears the previous completion's loop state" -ForegroundColor Green
    $script:PASS++
}

# 18k: atomicity, from both ends. No temp survives a success, and structurally
# the writer stages+renames rather than writing straight at the destination.
# The bash half asserts this with awk/grep over its own function body; the ps1
# equivalent asserts the three constructs that make the write atomic and
# encoding-correct, and the absence of the one that would not be.
$g18k = New-G18Project 'k'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18k
$g18kTemps = @(Get-ChildItem -Path (Join-Path $g18k '.stride') -Filter 'loop-state.*' -File -ErrorAction SilentlyContinue)
Assert-Eq "18k: no temp file survives a successful write" "0" ([string]$g18kTemps.Count)
$g18kSrc = Get-Content -LiteralPath $HookScript -Raw
$g18kBody = ''
if ($g18kSrc -cmatch '(?s)function Write-LoopState \{.*?\n\}') { $g18kBody = $Matches[0] }
Assert-Contains "18k: the writer renames a staged temp into place" 'Move-Item' $g18kBody
Assert-Contains "18k: the writer emits UTF-8 without BOM via WriteAllText" 'WriteAllText' $g18kBody
Assert-NotContains "18k: the writer never uses Set-Content (ANSI + CRLF on 5.1)" 'Set-Content' $g18kBody

# 18l: the file carries exactly the four documented keys and nothing else —
# never the response body, task free text, or the Bearer token that rides in
# the same hook input the session id is read from.
$g18l = New-G18Project 'l'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' `
    -Command "curl -sS -X PATCH $G18Url/api/tasks/99/complete -H 'Authorization: Bearer stride_dev_SECRETVALUE' -d @p.json | tee r.json" `
    -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18l
$g18lKeys = ''
try { $g18lKeys = (((Get-G18Raw -Dir $g18l) | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object) -join ' ' } catch { $g18lKeys = '' }
Assert-Eq "18l: the file carries exactly the four documented keys" "completed_at identifier needs_review session_id" $g18lKeys
Assert-NotContains "18l: the loop state never carries the Bearer token value" 'SECRETVALUE' (Get-G18Raw -Dir $g18l)
Assert-NotContains "18l: the loop state never carries the Authorization header" 'Bearer' (Get-G18Raw -Dir $g18l)

# 18m: the full claim -> complete -> claim cycle, asserted as ONE triple rather
# than three separate assertions: split up, the middle one could be quietly
# weakened while the other two still passed.
$g18m = New-G18Project 'm'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18ClaimCmd `
    -Stdout '{"data":{"id":99,"identifier":"W2147"},"hook":{"name":"before_doing"}}') -Phase 'post' -ProjectDir $g18m
$g18mAfterClaim = if (Test-G18StateExists -Dir $g18m) { 'present' } else { 'absent' }
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18m
$g18mAfterComplete = if (Test-G18StateExists -Dir $g18m) { 'present' } else { 'absent' }
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18ClaimCmd `
    -Stdout '{"data":{"id":100,"identifier":"W2148"},"hook":{"name":"before_doing"}}') -Phase 'post' -ProjectDir $g18m
$g18mAfterNext = if (Test-G18StateExists -Dir $g18m) { 'present' } else { 'absent' }
Assert-Eq "18m: claim -> complete -> claim leaves the state absent/present/absent" `
    "absent present absent" "$g18mAfterClaim $g18mAfterComplete $g18mAfterNext"

# 18n: the clear is UNCONDITIONAL, including on a FAILED claim. The claim that
# fails most often is the one against an empty ready queue — how essentially
# every session ends — and a record preserved there is byte-identical to one
# left by an agent that completed and never claimed at all.
$g18n = New-G18Project 'n'
Set-Content -Path (Join-Path $g18n $G18State) `
    -Value '{"identifier":"W_OLD","needs_review":false,"completed_at":"2020-01-01T00:00:00Z","session_id":"old"}' -Encoding UTF8 -NoNewline
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18ClaimCmd `
    -Stdout '{"errors":{"base":["no task available"]}}') -Phase 'post' -ProjectDir $g18n
if (Test-G18StateExists -Dir $g18n) {
    Write-Host "  FAIL: 18n: an empty-queue claim must still clear (no ambiguous record)" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18n: an empty-queue claim still clears (no ambiguous record)" -ForegroundColor Green
    $script:PASS++
}

# 18o: and a claim whose payload cannot be PARSED still clears. THIS is the
# case that pins the clear's placement on this port: the sibling
# .stride-changed-files.json / .stride-diff-upload-state clears look
# unconditional but sit inside the caching block's `try`, whose
# `$Input | ConvertFrom-Json` throws on exactly this input — so a loop-state
# clear placed beside them would be skipped here and diverge from the bash half.
$g18o = New-G18Project 'o'
Set-Content -Path (Join-Path $g18o $G18State) `
    -Value '{"identifier":"W_OLD","needs_review":false,"completed_at":"2020-01-01T00:00:00Z","session_id":"old"}' -Encoding UTF8 -NoNewline
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18ClaimCmd `
    -Stdout '{"data":{"id":9 TRUNCA') -Phase 'post' -ProjectDir $g18o
if (Test-G18StateExists -Dir $g18o) {
    Write-Host "  FAIL: 18o: an unparsable claim must still clear (safe direction)" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18o: an unparsable claim still clears (safe direction)" -ForegroundColor Green
    $script:PASS++
}

# 18p: a completion carrying NO tool_response at all. Under Set-StrictMode
# -Version Latest an absent property read is a terminating error, so this is
# the case that proves every level is guarded.
$g18p = New-G18Project 'p'
$g18pInput = [ordered]@{ session_id = 's'; tool_input = @{ command = $G18CompleteCmd } } | ConvertTo-Json -Compress -Depth 6
$g18pRes = Invoke-HookScript -InputJson $g18pInput -Phase 'post' -ProjectDir $g18p
Assert-Exit "18p: an absent tool_response does not fail the hook" 0 $g18pRes.ExitCode
# The diagnostic channel must stay QUIET here: there was no body at all, so
# announcing a parse failure would claim something that never happened.
Assert-NotContains "18p: an absent body is not announced as unparsable" 'unparsable' $g18pRes.Stderr
if (Test-G18StateExists -Dir $g18p) {
    Write-Host "  FAIL: 18p: an absent tool_response must write no loop state" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18p: an absent tool_response writes no loop state" -ForegroundColor Green
    $script:PASS++
}

# 18q: the charset gate must agree with the bash twin, and the one input where
# the two shells can silently disagree is a TRAILING newline. bash reads both
# values through `$( )`, which strips linefeeds and leaves a carriage return
# behind; this half therefore strips LF ONLY before validating. Stripping CRLF
# here would record "abc" where bash records "unknown" — closing the LF
# divergence by opening a CR one.
$g18q1 = New-G18Project 'q1'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId "abc`n" -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18q1
Assert-Eq "18q: a trailing newline in the session id is stripped, not refused" "abc" (Get-G18Field -Dir $g18q1 -Name 'session_id')
$g18q2 = New-G18Project 'q2'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId "abc`r`n" -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18q2
Assert-Eq "18q: a trailing CRLF in the session id is refused" "unknown" (Get-G18Field -Dir $g18q2 -Name 'session_id')
$g18q3 = New-G18Project 'q3'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId "a`nb" -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18q3
Assert-Eq "18q: an interior newline in the session id is refused" "unknown" (Get-G18Field -Dir $g18q3 -Name 'session_id')

# 18r: an UNPARSABLE completion body is announced, because the completion may
# have succeeded server-side with only the harness's copy cut. A plain 422 and
# a well-formed scalar body stay QUIET — the reason the decision is made by an
# actual parse rather than by "did the payload resolve to $null", which is true
# for four distinct reasons of which only one is a parse failure.
$g18r1 = New-G18Project 'r1'
$g18r1Res = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"data":{"id":99,"ident TRUNCA') -Phase 'post' -ProjectDir $g18r1
Assert-Contains "18r: an unparsable completion body is announced" 'unparsable' $g18r1Res.Stderr
$g18r2 = New-G18Project 'r2'
$g18r2Res = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd -Stdout 'false') -Phase 'post' -ProjectDir $g18r2
Assert-NotContains "18r: a well-formed scalar body is not announced as unparsable" 'unparsable' $g18r2Res.Stderr
$g18r3 = New-G18Project 'r3'
$g18r3Res = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"errors":{"base":["bad"]}}') -Phase 'post' -ProjectDir $g18r3
Assert-NotContains "18r: a plain 422 records nothing and stays quiet" 'unparsable' $g18r3Res.Stderr

# 18s: the two never-fatal failure paths that need POSIX permissions, plus the
# non-regular-file guard that does not. `Move-Item` onto a DIRECTORY relocates
# the temp INSIDE it instead of failing, so the writer's own catch never runs:
# the record would land where no reader looks and the temp would survive
# indefinitely. The guard exists because the move's success is the wrong signal.
$g18s = New-G18Project 's'
New-Item -ItemType Directory -Path (Join-Path $g18s $G18State) -Force | Out-Null
$g18sRes = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18s
Assert-Exit "18s: a non-regular-file destination does not fail the completion" 0 $g18sRes.ExitCode
Assert-Contains "18s: a non-regular-file destination is announced on stderr" 'not a regular file' $g18sRes.Stderr
$g18sStray = @(Get-ChildItem -Path (Join-Path $g18s $G18State) -Filter 'loop-state.*' -File -ErrorAction SilentlyContinue)
Assert-Eq "18s: and no temp is relocated inside it" "0" ([string]$g18sStray.Count)

if ($IsWindows) {
    Write-Host "  SKIP: 18s: POSIX-permission cases (unwritable/unclearable .stride) — bash 21m/21t cover them"
} else {
    # An unwritable .stride/ is announced and swallowed: the loop state is a
    # gate input, not a correctness dependency, so it must never fail the
    # completion.
    $g18sw = New-G18Project 'sw'
    & chmod 500 (Join-Path $g18sw '.stride') 2>$null
    $g18swRes = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18sw
    & chmod 700 (Join-Path $g18sw '.stride') 2>$null
    Assert-Exit "18s: an unwritable .stride does not fail the completion" 0 $g18swRes.ExitCode
    Assert-Contains "18s: an unwritable .stride is announced on stderr" 'loop state' $g18swRes.Stderr

    # A clear that FAILS must be announced too. Before this, an operator was
    # told when a record could not be WRITTEN but never when one could not be
    # CLEARED — the direction the design itself calls dangerous.
    $g18sc = New-G18Project 'sc'
    $null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18sc
    & chmod 555 (Join-Path $g18sc '.stride') 2>$null
    $g18scRes = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18ClaimCmd `
        -Stdout '{"data":{"id":902,"identifier":"W2902","needs_review":false},"hook":{"name":"before_doing"}}') -Phase 'post' -ProjectDir $g18sc
    & chmod 755 (Join-Path $g18sc '.stride') 2>$null
    Assert-Exit "18s: an unclearable loop state does not fail the claim" 0 $g18scRes.ExitCode
    Assert-Contains "18s: an unclearable loop state is announced on stderr" 'could not clear the loop state' $g18scRes.Stderr
}

# 18t: AC5 — "both halves produce a byte-identical record" — asserted
# MECHANICALLY, and deliberately redundant with bash 21w so the parity claim is
# checked whichever suite a reviewer runs. The same input goes through both
# halves; completed_at's VALUE is normalised away (it is a wall clock, so the
# two runs legitimately differ) but only AFTER both raw files have been
# format-checked, so the normalisation cannot mask a culture or precision
# divergence. Everything else — key order, the boolean literal, compact
# separators, the single trailing LF, the encoding — is inside the compared
# bytes.
#
# SKIP, never PASS, when bash is absent: a missing runtime must not be mistaken
# for a passing parity check.
$g18Bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $g18Bash) {
    Write-Host "  SKIP: 18t: bash not available — cross-half byte parity unverified"
} else {
    $g18tP = New-G18Project 't-ps1'
    $g18tB = New-G18Project 't-bash'
    $g18tIn = New-G18Input -SessionId 'sess-parity' -Command $G18CompleteCmd -Stdout $G18Ok
    $null = Invoke-HookScript -InputJson $g18tIn -Phase 'post' -ProjectDir $g18tP
    $g18tShScript = Join-Path $ScriptDir 'stride-hook.sh'
    $g18tInFile = Join-Path $TmpDir 'g18t-input.json'
    [System.IO.File]::WriteAllText($g18tInFile, $g18tIn)
    $g18tPsi = [System.Diagnostics.ProcessStartInfo]::new()
    $g18tPsi.FileName = 'bash'
    $g18tPsi.Arguments = "`"$g18tShScript`" post"
    $g18tPsi.RedirectStandardInput = $true
    $g18tPsi.RedirectStandardOutput = $true
    $g18tPsi.RedirectStandardError = $true
    $g18tPsi.UseShellExecute = $false
    $g18tPsi.Environment['CLAUDE_PROJECT_DIR'] = $g18tB
    $g18tProc = [System.Diagnostics.Process]::Start($g18tPsi)
    $g18tProc.StandardInput.Write($g18tIn)
    $g18tProc.StandardInput.Close()
    $null = $g18tProc.StandardOutput.ReadToEnd()
    $null = $g18tProc.StandardError.ReadToEnd()
    $g18tProc.WaitForExit()

    $g18tRawP = Get-G18Raw -Dir $g18tP
    $g18tRawB = Get-G18Raw -Dir $g18tB
    $g18tRe = '"completed_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"'
    $g18tFmtP = if ($g18tRawP -cmatch $g18tRe) { 'ok' } else { 'no' }
    $g18tFmtB = if ($g18tRawB -cmatch $g18tRe) { 'ok' } else { 'no' }
    Assert-Eq "18t: both halves emit the same completed_at format" "ok ok" "$g18tFmtP $g18tFmtB"
    $g18tNormP = $g18tRawP -creplace '"completed_at":"[^"]*"', '"completed_at":"X"'
    $g18tNormB = $g18tRawB -creplace '"completed_at":"[^"]*"', '"completed_at":"X"'
    if ($g18tNormP -ceq $g18tNormB -and $g18tNormP) {
        Write-Host "  PASS: 18t: both halves produce a byte-identical record" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 18t: the two halves produced different bytes" -ForegroundColor Red
        Write-Host "    ps1:  $g18tNormP"
        Write-Host "    bash: $g18tNormB"
        $script:FAIL++
    }
}

# 18u: the charset gate must agree with the bash twin on NON-ASCII input. .NET's
# `A-Za-z0-9` ranges are strictly code-point based and refuse "é"; a bracket
# RANGE in bash's `case` glob is collation-based and would accept it, so the
# bash half enumerates its character set instead. Both halves must refuse here
# — for a session id that is "unknown" on both sides, and for an identifier it
# is no record at all on both sides.
$g18u1 = New-G18Project 'u1'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 'abcé' -Command $G18CompleteCmd -Stdout $G18Ok) -Phase 'post' -ProjectDir $g18u1
Assert-Eq "18u: a non-ASCII session id is refused, not collated in" "unknown" (Get-G18Field -Dir $g18u1 -Name 'session_id')
$g18u2 = New-G18Project 'u2'
$null = Invoke-HookScript -InputJson (New-G18Input -SessionId 's' -Command $G18CompleteCmd `
    -Stdout '{"data":{"id":99,"identifier":"W2147é","needs_review":false},"hooks":[{"name":"before_review"}]}') `
    -Phase 'post' -ProjectDir $g18u2
if (Test-G18StateExists -Dir $g18u2) {
    Write-Host "  FAIL: 18u: a non-ASCII identifier must be refused outright, wrote: $(Get-G18Raw -Dir $g18u2)" -ForegroundColor Red
    $script:FAIL++
} else {
    Write-Host "  PASS: 18u: a non-ASCII identifier is refused outright" -ForegroundColor Green
    $script:PASS++
}

# 18v: `tool_response.stdout` carrying a JSON OBJECT rather than a string. The
# bash twin resolves that field with `jq -r`, which re-serialises the object, so
# it parses and records. Reading it here as [string] would render PowerShell's
# "@{...}" form, fail to parse, record nothing, and announce an unparsable body
# — the divergence ConvertTo-OwnCallText exists to close. Unreachable with
# today's harness, which always sends stdout as a string, but this is the parse
# boundary the task's pitfall names.
$g18v = New-G18Project 'v'
$g18vIn = [ordered]@{
    session_id    = 'sess-obj'
    tool_input    = @{ command = $G18CompleteCmd }
    tool_response = @{ stdout = ($G18Ok | ConvertFrom-Json) }
} | ConvertTo-Json -Compress -Depth 10
$g18vRes = Invoke-HookScript -InputJson $g18vIn -Phase 'post' -ProjectDir $g18v
Assert-Eq "18v: an object-shaped tool_response.stdout still records" "W2147" (Get-G18Field -Dir $g18v -Name 'identifier')
Assert-Eq "18v: and its session id survives the same path" "sess-obj" (Get-G18Field -Dir $g18v -Name 'session_id')
Assert-NotContains "18v: an object-shaped stdout is not announced as unparsable" 'unparsable' $g18vRes.Stderr

# 18w: STREAM DISCIPLINE on the same branch 18v exercises. ConvertTo-Json emits
# "Resulting JSON is truncated..." on the WARNING stream once a value nests
# deeper than its -Depth, and pwsh writes WARNING to STDOUT — which would
# corrupt the single JSON document this hook is contracted to emit, and diverge
# from the bash twin, whose `jq` has no depth limit and writes nothing. The
# fixture nests 120 deep, past ConvertTo-Json's maximum -Depth of 100, so the
# guard is -WarningAction SilentlyContinue rather than the depth alone; 18v's
# shallow fixture cannot reach this.
#
# The input is built as a STRING rather than via ConvertTo-Json, because the
# test would otherwise hit the same 100 limit constructing its own fixture.
$g18wDeep = ('{"n":' * 120) + '"leaf"' + ('}' * 120)
$g18wStdout = '{"data":{"id":99,"identifier":"W2147","needs_review":false},' +
              '"hooks":[{"name":"before_review"}],"deep":' + $g18wDeep + '}'
$g18wIn = '{"session_id":"sess-deep","tool_input":{"command":"' + $G18CompleteCmd +
          '"},"tool_response":{"stdout":' + $g18wStdout + '}}'
$g18w = New-G18Project 'w'
$g18wRes = Invoke-HookScript -InputJson $g18wIn -Phase 'post' -ProjectDir $g18w
Assert-NotContains "18w: a deeply nested stdout emits no WARNING on stdout" 'WARNING' $g18wRes.Stdout
Assert-NotContains "18w: nor any truncation notice on stdout" 'truncated' $g18wRes.Stdout
Assert-Exit "18w: a deeply nested stdout does not fail the hook" 0 $g18wRes.ExitCode
# The four fields all sit at depth 2, so they survive any truncation below them.
Assert-Eq "18w: and the record is still correct" "W2147" (Get-G18Field -Dir $g18w -Name 'identifier')
Assert-Eq "18w: including the session id" "sess-deep" (Get-G18Field -Dir $g18w -Name 'session_id')

# ============================================================
# Test Group 19: agentStop gate (W2148)
# ============================================================
# PowerShell mirror of test-stride-hook.sh Test Group 22.
#
# Cases that must NOT reach the network are pointed at a LIVE listener that
# would otherwise block, never at a closed port: aiming them at a closed port
# would let them reach exit 0 through the transport-failure branch and stay
# green even with the short-circuit under test deleted.
#
# NOT MIRRORED, with the reason recorded so each gap reads as a decision:
#   * 22t / 22u (missing jq, missing curl) — this half shells out to neither.
#   * 22aa / 22p (bash source inspection) — replaced by 19aa, the PowerShell
#     stdout-discipline equivalent.
#   * 22z's runtime simulator and 22n's registration assertions — both are
#     runtime- and file-level rather than per-half, so bash asserts them once
#     for the pair rather than each half asserting the same JSON twice.
#   * The /dev/null counter divergence: bash refuses the character device at
#     the pre-check, this half permits via the read-back. Both permit, both for
#     bounding-related reasons, which is the invariant.
Write-Host ""
Write-Host "=== Test Group 19: agentStop gate (W2148) ==="

$G19Gate = Join-Path $ScriptDir 'stride-stop-gate.ps1'
$G19GateSh = Join-Path $ScriptDir 'stride-stop-gate.sh'
$G19Token = 'NOT-A-REAL-TOKEN-g19-fixture'

# Spawn a child pwsh so stdout and stderr are captured independently, and
# REMOVE the gate's own control variables from the child environment — an
# ambient STRIDE_ALLOW_STOP=1 would send every case down the escape hatch, and
# "exit 0 with empty stdout" is exactly what that produces, so every permit
# case would pass vacuously.
function Invoke-G19Gate {
    param([string]$Cwd, [hashtable]$Payload = $null, [hashtable]$Env = $null)
    $doc = [ordered]@{ cwd = $Cwd; session_id = 'g19'; hook_event_name = 'Stop'; stop_reason = 'end_turn' }
    if ($Payload) { foreach ($k in $Payload.Keys) { $doc[$k] = $Payload[$k] } }
    $json = $doc | ConvertTo-Json -Compress -Depth 6

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.Arguments = "-NoProfile -File `"$G19Gate`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($key in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
        $psi.Environment[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
    }
    foreach ($drop in @('STRIDE_ALLOW_STOP', 'STRIDE_STOP_GATE_MAX_BLOCKS', 'CLAUDE_PROJECT_DIR')) {
        if ($psi.Environment.ContainsKey($drop)) { $null = $psi.Environment.Remove($drop) }
    }
    if ($Env) { foreach ($k in $Env.Keys) { $psi.Environment[$k] = [string]$Env[$k] } }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($json)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ ExitCode = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

function New-G19Project {
    param([string]$Name, [string]$Url = 'https://api.example.invalid')
    $d = Join-Path $TmpDir "g19-$Name"
    if (Test-Path $d) { Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path (Join-Path $d '.stride') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $d '.stride_auth.md') `
        -Value "# auth`n`n- **API URL:** ``$Url```n- **API Token:** ``$G19Token```n" -Encoding UTF8
    return $d
}

function Set-G19State {
    param([string]$Dir, [string]$Ident, [bool]$NeedsReview)
    $nr = if ($NeedsReview) { 'true' } else { 'false' }
    Set-Content -LiteralPath (Join-Path $Dir '.stride/.loop-state.json') `
        -Value "{`"identifier`":`"$Ident`",`"needs_review`":$nr,`"completed_at`":`"2026-01-01T00:00:00Z`",`"session_id`":`"g19`"}" `
        -Encoding UTF8 -NoNewline
}

function Get-G19Decision {
    param([string]$Stdout)
    if (-not $Stdout) { return '' }
    try { return [string](($Stdout | ConvertFrom-Json).decision) } catch { return '' }
}

# A real HttpListener on a rotating loopback port. Loopback is why the gate's
# SSRF guard must permit 127.0.0.1 in cleartext.
$G19Port = Get-Random -Minimum 24000 -Maximum 24900
$G19Body = '{"data":{"id":1,"identifier":"W2148"}}'
# The listener serves whatever body and status code the control files hold, so
# a case can vary the RESPONSE SHAPE without standing up a new listener. This
# is what lets Group 19 mirror Group 22's response-shape cases rather than
# omitting them — in particular 19w2, which is the only test of the
# TrimStart().StartsWith('{') guard the gate carries specifically to close a
# cross-half parity divergence.
$G19Ctl = Join-Path $TmpDir 'g19-ctl'
New-Item -ItemType Directory -Path $G19Ctl -Force | Out-Null
function Set-G19Response {
    param([string]$Body, [int]$Code = 200)
    Set-Content -LiteralPath (Join-Path $G19Ctl 'body.txt') -Value $Body -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $G19Ctl 'code.txt') -Value ([string]$Code) -Encoding UTF8 -NoNewline
}
Set-G19Response -Body $G19Body -Code 200
$G19Job = Start-Job -ScriptBlock {
    param($port, $ctl)
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    try {
        while ($true) {
            $ctx = $listener.GetContext()
            $b = ''
            $c = 200
            try { $b = [System.IO.File]::ReadAllText((Join-Path $ctl 'body.txt')) } catch { $b = '' }
            try { $c = [int]([System.IO.File]::ReadAllText((Join-Path $ctl 'code.txt'))) } catch { $c = 200 }
            $ctx.Response.StatusCode = $c
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($b)
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()
        }
    } finally { $listener.Stop() }
} -ArgumentList $G19Port, $G19Ctl

try {
    if (-not (Wait-ForListener -Port $G19Port -TimeoutSeconds 15)) {
        Write-Host "  SKIP: Test Group 19 (the loopback listener did not come up)"
    } else {
        $G19Url = "http://127.0.0.1:$G19Port"

        # --- The one block path ------------------------------------------
        $d = New-G19Project 'a' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d
        Assert-Exit "19a: the block path exits 0" 0 $r.ExitCode
        Assert-Eq "19a: the decision is block" "block" (Get-G19Decision -Stdout $r.Stdout)
        # 19a2: block, NOT Gemini's deny — the wrong token means no block at all.
        Assert-NotContains "19a2: the decision is not the Gemini spelling" '"decision":"deny"' $r.Stdout
        # 19b (AC4): the reason names the CLAIMABLE task, not the completed one.
        Assert-Contains "19b: the reason names the claimable identifier" "W2148" $r.Stdout
        Assert-NotContains "19b: the reason does not name the completed identifier" "W2147" $r.Stdout
        # 19b2: exactly two keys, one line, and NOT the permission contract.
        $g19Keys = ''
        try { $g19Keys = ((($r.Stdout | ConvertFrom-Json).PSObject.Properties.Name) | Sort-Object) -join ' ' } catch { $g19Keys = '' }
        Assert-Eq "19b2: stdout carries exactly the two documented keys" "decision reason" $g19Keys
        Assert-Eq "19b2: stdout is exactly one non-empty line" "1" `
            ([string](@($r.Stdout -split "`n" | Where-Object { $_.Trim() })).Count)
        Assert-NotContains "19b2: the permission-request contract is not emitted" 'permissionDecision' $r.Stdout

        # --- Permit branches, each asserting its OWN reason ---------------
        # 19c: no loop-state file — a SILENT permit, so silence is what pins it.
        $d = New-G19Project 'c' -Url $G19Url
        $r = Invoke-G19Gate -Cwd $d
        Assert-Exit "19c: no loop state exits 0" 0 $r.ExitCode
        Assert-Eq "19c: no loop state writes nothing to stdout" "" $r.Stdout.Trim()
        Assert-Eq "19c: no loop state is silent on stderr" "" $r.Stderr.Trim()
        # POSITIVE CONTROL: one file away, the same fixture blocks.
        Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d
        Assert-Eq "19c: positive control - adding loop state blocks" "block" (Get-G19Decision -Stdout $r.Stdout)

        # 19f: needs_review true
        $d = New-G19Project 'f' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $true
        $r = Invoke-G19Gate -Cwd $d
        Assert-Eq "19f: needs_review true permits" "" $r.Stdout.Trim()
        Assert-Contains "19f: and says the completed task needs review" 'the completed task needs human review' $r.Stderr

        # 19f2: unparsable / not-an-object / non-boolean needs_review
        $d = New-G19Project 'f2' -Url $G19Url
        Set-Content -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Value '{"identifier":"W2147", TRUNCA' -Encoding UTF8 -NoNewline
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19f2: an unparsable loop state is announced" 'the loop-state file could not be parsed' $r.Stderr
        # A bare JSON STRING is a valid single document. This is the case the
        # -is [PSCustomObject] test would wave through, since every PowerShell
        # scalar is viewable as one.
        Set-Content -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Value '"just a string"' -Encoding UTF8 -NoNewline
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19f2: a non-object loop state reports the same reason" 'the loop-state file could not be parsed' $r.Stderr
        Set-Content -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Value '{"identifier":"W2147","needs_review":"false"}' -Encoding UTF8 -NoNewline
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19f2: a STRING needs_review is not a boolean false" 'records no usable needs_review' $r.Stderr

        # 19f3: the completed identifier's three refusals, in the bash half's order
        $d = New-G19Project 'f3' -Url $G19Url
        Set-Content -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Value '{"needs_review":false}' -Encoding UTF8 -NoNewline
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19f3: no completed identifier is announced" 'records no identifier' $r.Stderr
        Set-Content -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Value '{"identifier":"W 2147","needs_review":false}' -Encoding UTF8 -NoNewline
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19f3: a malformed completed identifier is refused" 'the completed identifier is not identifier-shaped' $r.Stderr
        $g19Long = 'W' * 65
        Set-Content -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Value "{`"identifier`":`"$g19Long`",`"needs_review`":false}" -Encoding UTF8 -NoNewline
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19f3: an over-long completed identifier is refused" 'the completed identifier is longer than 64 characters' $r.Stderr

        # 19d: an unreachable API. A closed port on loopback, so the SSRF guard
        # still permits it through and the transport branch is what fires.
        $d = New-G19Project 'd' -Url 'http://127.0.0.1:1'; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19d: a transport failure permits and says so" 'the API could not be reached' $r.Stderr

        # 19d4 / 19y: a missing URL or token names the PAIR, never a value
        $d = New-G19Project 'd4' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        Remove-Item -LiteralPath (Join-Path $d '.stride_auth.md') -Force
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19d4: no auth file permits" 'no API URL or token could be resolved' $r.Stderr
        Set-Content -LiteralPath (Join-Path $d '.stride_auth.md') -Value "# auth`n`n- **API URL:** ``$G19Url```n" -Encoding UTF8
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19y: a URL with no token permits" 'no API URL or token could be resolved' $r.Stderr

        # 19ad: the cleartext-http SSRF guard. Pointed at a host that is NOT
        # loopback, and asserted to permit BEFORE any request is attempted.
        $d = New-G19Project 'ad' -Url 'http://evil.example.com'; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19ad: cleartext http to a non-loopback host is refused" 'cleartext http to the non-loopback host evil.example.com' $r.Stderr
        # A name that merely STARTS with 127. is an ordinary public domain.
        $d = New-G19Project 'ad2' -Url 'http://127.0.0.1.evil.example.com'; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19ad: a 127-prefixed NAME is not loopback" 'cleartext http to the non-loopback host' $r.Stderr
        # An unrecognised scheme
        $d = New-G19Project 'ad3' -Url 'ftp://api.example.invalid'; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19ad2: an unrecognised scheme permits" 'no API URL or token could be resolved' $r.Stderr

        # 19k: stop_hook_active short-circuits, silently, with no counter spend.
        # Pointed at the LIVE listener, so a deleted short-circuit would BLOCK
        # rather than fall through some other permit.
        $d = New-G19Project 'k' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d -Payload @{ stop_hook_active = $true }
        Assert-Exit "19k: stop_hook_active exits 0" 0 $r.ExitCode
        Assert-Eq "19k: stop_hook_active writes nothing to stdout" "" $r.Stdout.Trim()
        Assert-Eq "19k: stop_hook_active is silent" "" $r.Stderr.Trim()
        Assert-Eq "19k: and spends no counter budget" "absent" `
            $(if (Test-Path -LiteralPath (Join-Path $d '.stride/.stop-gate-blocks')) { 'present' } else { 'absent' })
        # POSITIVE CONTROL: without the flag, the same fixture blocks.
        $r = Invoke-G19Gate -Cwd $d
        Assert-Eq "19k: positive control - without the flag it blocks" "block" (Get-G19Decision -Stdout $r.Stdout)

        # 19l: the operator escape hatch
        $d = New-G19Project 'l' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $r = Invoke-G19Gate -Cwd $d -Env @{ STRIDE_ALLOW_STOP = '1' }
        Assert-Eq "19l: STRIDE_ALLOW_STOP=1 permits" "" $r.Stdout.Trim()
        Assert-Contains "19l: and says so" 'STRIDE_ALLOW_STOP=1 was set' $r.Stderr

        # --- The bounded counter ------------------------------------------
        # 19h: default budget 2 — block, block, then permit.
        $d = New-G19Project 'h' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $h1 = Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d).Stdout
        $h2 = Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d).Stdout
        $r3 = Invoke-G19Gate -Cwd $d
        $h3 = Get-G19Decision -Stdout $r3.Stdout
        if (-not $h3) { $h3 = 'permit' }
        Assert-Eq "19h: the default budget blocks twice then permits" "block block permit" "$h1 $h2 $h3"
        Assert-Contains "19h: and says the budget is spent" 'the re-block budget for this completion is spent' $r3.Stderr
        # 19r: a fourth end still permits, and the spent record is RETAINED —
        # deleting it would cycle 2,2,0,2,2,0 forever.
        $r4 = Invoke-G19Gate -Cwd $d
        Assert-Eq "19r: a fourth end still permits" "" $r4.Stdout.Trim()
        Assert-Eq "19r: the spent record is retained, not deleted" "present" `
            $(if (Test-Path -LiteralPath (Join-Path $d '.stride/.stop-gate-blocks')) { 'present' } else { 'absent' })
        # 19h2: a NEW completion re-keys the counter and earns a fresh budget.
        Set-G19State -Dir $d -Ident 'W2199' -NeedsReview $false
        Assert-Eq "19h2: a new completed identifier earns a fresh budget" "block" `
            (Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d).Stdout)
        # 19h3: clearing the loop state clears the counter.
        Remove-Item -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Force
        $null = Invoke-G19Gate -Cwd $d
        Assert-Eq "19h3: clearing loop state clears the counter" "absent" `
            $(if (Test-Path -LiteralPath (Join-Path $d '.stride/.stop-gate-blocks')) { 'present' } else { 'absent' })

        # 19q: a malformed budget override falls back to 2 and NEVER wedges.
        foreach ($bad in @('off', '9999999999')) {
            $d = New-G19Project "q-$bad" -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
            $seq = @()
            foreach ($i in 1..3) {
                $dec = Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d -Env @{ STRIDE_STOP_GATE_MAX_BLOCKS = $bad }).Stdout
                if (-not $dec) { $dec = 'permit' }
                $seq += $dec
            }
            Assert-Eq "19q: STRIDE_STOP_GATE_MAX_BLOCKS=$bad falls back to 2, never wedges" `
                "block block permit" ($seq -join ' ')
        }

        # 19ac: a counter destination that is not a regular file is refused
        # rather than blocking uncounted — a wedged session is worse than a
        # missed gate.
        $d = New-G19Project 'ac' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        New-Item -ItemType Directory -Path (Join-Path $d '.stride/.stop-gate-blocks') -Force | Out-Null
        $r = Invoke-G19Gate -Cwd $d
        Assert-Eq "19ac: a directory counter permits rather than blocking uncounted" "" $r.Stdout.Trim()
        Assert-Contains "19ac: and says the block could not be bounded" 'could not be bounded' $r.Stderr

        # 19af: a counter that is a SYMLINK is refused. Test-Path -PathType Leaf
        # is TRUE for a link to a regular file and Set-Content FOLLOWS it,
        # truncating the target — anywhere the agent user can write. Test-Path
        # is unusable for the dangling case because it resolves the link and
        # reports false, after which Set-Content would create the target
        # outright, so the guard reads the ReparsePoint attribute with -Force.
        # The victim file is the assertion; the control proves the gate reached
        # the counter guard rather than permitting earlier.
        $d = New-G19Project 'af' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        Assert-Eq "19af: control - the fixture reaches the counter and blocks" "block" `
            (Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d).Stdout)
        Remove-Item -LiteralPath (Join-Path $d '.stride/.stop-gate-blocks') -Force -ErrorAction SilentlyContinue
        $g19Victim = Join-Path $d 'victim.txt'
        Set-Content -LiteralPath $g19Victim -Value 'PRECIOUS' -Encoding UTF8 -NoNewline
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $d '.stride/.stop-gate-blocks') -Target $g19Victim -Force
        $r = Invoke-G19Gate -Cwd $d
        Assert-Eq "19af: a symlinked counter permits rather than following the link" "" $r.Stdout.Trim()
        Assert-Contains "19af: and says the counter is a symbolic link" 'the block counter is a symbolic link' $r.Stderr
        Assert-Eq "19af: the symlink target is NOT truncated" "PRECIOUS" `
            ((Get-Content -LiteralPath $g19Victim -Raw -ErrorAction SilentlyContinue))
        # A dangling link must not be followed into existence either.
        Remove-Item -LiteralPath (Join-Path $d '.stride/.stop-gate-blocks') -Force -ErrorAction SilentlyContinue
        $g19Absent = Join-Path $d 'victim-absent.txt'
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $d '.stride/.stop-gate-blocks') -Target $g19Absent -Force
        $null = Invoke-G19Gate -Cwd $d
        Assert-Eq "19af: a dangling symlink target is never created" "absent" `
            $(if (Test-Path -LiteralPath $g19Absent) { 'present' } else { 'absent' })
        Remove-Item -LiteralPath (Join-Path $d '.stride/.stop-gate-blocks') -Force -ErrorAction SilentlyContinue

        # --- Security ------------------------------------------------------
        # 19i: the token never reaches stdout OR stderr, on any response shape.
        foreach ($case in @(@{ n = 'live'; u = $G19Url }, @{ n = 'closed'; u = 'http://127.0.0.1:1' })) {
            $d = New-G19Project ('i-' + $case.n) -Url $case.u; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
            $r = Invoke-G19Gate -Cwd $d
            Assert-NotContains ("19i: the token never reaches stdout (" + $case.n + ")") $G19Token $r.Stdout
            Assert-NotContains ("19i: the token never reaches stderr (" + $case.n + ")") $G19Token $r.Stderr
        }

        # --- AC3 / AC5 -----------------------------------------------------
        # 19z2: block and every permit alike exit 0.
        $d = New-G19Project 'z2' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false
        $e1 = (Invoke-G19Gate -Cwd $d).ExitCode
        Remove-Item -LiteralPath (Join-Path $d '.stride/.loop-state.json') -Force
        $e2 = (Invoke-G19Gate -Cwd $d).ExitCode
        Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $true
        $e3 = (Invoke-G19Gate -Cwd $d).ExitCode
        Assert-Eq "19z2: block and every permit alike exit 0" "0 0 0" "$e1 $e2 $e3"


        # --- Response-shape branches, mirroring Group 22 ------------------
        # These were previously absent, which left the gate's
        # TrimStart().StartsWith('{') guard (added specifically to close a
        # cross-half divergence) with no test on this half at all.
        $d = New-G19Project 'shape' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $false

        # 19w: an unparsable body
        Set-G19Response -Body '<html>hi</html>' -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19w: an unparsable body is announced" 'the API response could not be parsed' $r.Stderr

        # 19w2: a top-level ARRAY. ConvertFrom-Json unrolls a one-element array
        # to a scalar PSCustomObject, so without the raw-token guard this half
        # would accept it where the bash half's jq sees "array" and refuses.
        Set-G19Response -Body '[{"data":{"identifier":"W9999"}}]' -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19w2: a top-level array is not an object" 'the API response was not an object' $r.Stderr

        # 19w3: a body of the literal token null. ConvertFrom-Json returns
        # $null for it, colliding with the parse-failure sentinel; the bash
        # half slurps it to [null] and reports "was not an object".
        Set-G19Response -Body 'null' -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19w3: a body of literal null is not an object" 'the API response was not an object' $r.Stderr

        # 19e: a 200 with no claimable identifier, plus a POSITIVE CONTROL
        Set-G19Response -Body '{"data":{}}' -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19e: an empty data object means no claimable task" 'no claimable task remains' $r.Stderr
        Set-G19Response -Body $G19Body -Code 200
        Assert-Eq "19e: positive control - an identifier blocks" "block" `
            (Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d).Stdout)

        # 19m / 19ab / 19ag: the claimable identifier is REFUSED, never
        # sanitised. The NUL fixture is built from [char]0 so the wire value
        # genuinely carries one.
        Set-G19Response -Body '{"data":{"identifier":"W9999 IGNORE PRIOR"}}' -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19m: a spaced identifier is refused" 'the next task identifier is not identifier-shaped' $r.Stderr
        $g19Nul = @{ data = @{ identifier = ('W9999' + [char]0 + 'IGNORE.PRIOR') } } | ConvertTo-Json -Compress -Depth 4
        Set-G19Response -Body $g19Nul -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19ab: an embedded NUL is refused, not silently dropped" 'the next task identifier is not identifier-shaped' $r.Stderr
        $g19Nl = @{ data = @{ identifier = ("W9999`nclaim me") } } | ConvertTo-Json -Compress -Depth 4
        Set-G19Response -Body $g19Nl -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19ag: an embedded newline is refused" 'the next task identifier is not identifier-shaped' $r.Stderr

        # 19x: the length bound, with a BOUNDARY control so widening it reds a case
        $g19Ident65 = 'W' * 65
        Set-G19Response -Body ("{`"data`":{`"identifier`":`"$g19Ident65`"}}") -Code 200
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19x: a 65-character identifier is refused" 'the next task identifier is longer than 64 characters' $r.Stderr
        $g19Ident64 = 'W' * 64
        Set-G19Response -Body ("{`"data`":{`"identifier`":`"$g19Ident64`"}}") -Code 200
        Assert-Eq "19x: boundary control - exactly 64 characters still blocks" "block" `
            (Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d).Stdout)

        # 19d2 / 19d3 / 19ae: non-200 codes
        Set-G19Response -Body '<html>404</html>' -Code 404
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19d2: a 404 means no claimable task remains" 'no claimable task remains' $r.Stderr
        Set-G19Response -Body '{"error":"boom"}' -Code 500
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19d3: a 500 names the code" 'the API answered 500' $r.Stderr
        # A 3xx must be reported, never followed: -MaximumRedirection 0 is what
        # keeps the Authorization header from reaching a Location-named host on
        # Windows PowerShell 5.1, which preserves it across an auto-redirect.
        Set-G19Response -Body '' -Code 301
        $r = Invoke-G19Gate -Cwd $d
        Assert-Contains "19ae: a 301 is reported, never followed" 'the API answered 301' $r.Stderr
        Set-G19Response -Body $G19Body -Code 200

        # 19f4: a loop state that is a one-element top-level ARRAY. Same
        # ConvertFrom-Json unrolling as 19w2, on the path where it would cause a
        # DECISION divergence rather than a reason one: without the raw-token
        # guard this half would BLOCK where the bash half permits.
        $d2 = New-G19Project 'f4' -Url $G19Url
        Set-Content -LiteralPath (Join-Path $d2 '.stride/.loop-state.json') `
            -Value '[{"identifier":"W2147","needs_review":false}]' -Encoding UTF8 -NoNewline
        $r = Invoke-G19Gate -Cwd $d2
        Assert-Eq "19f4: an array-wrapped loop state permits, never blocks" "" $r.Stdout.Trim()
        Assert-Contains "19f4: and reports the same reason as the bash half" 'the loop-state file could not be parsed' $r.Stderr

        # 19h4: an unwritable .stride permits rather than blocking uncounted.
        # POSIX-only; bash 22h4 covers the same branch everywhere.
        if ($IsWindows) {
            Write-Host "  SKIP: 19h4 (POSIX permissions - bash 22h4 covers this branch)"
        } else {
            $d3 = New-G19Project 'h4' -Url $G19Url; Set-G19State -Dir $d3 -Ident 'W2147' -NeedsReview $false
            Assert-Eq "19h4: positive control - the fixture blocks while writable" "block" `
                (Get-G19Decision -Stdout (Invoke-G19Gate -Cwd $d3).Stdout)
            Remove-Item -LiteralPath (Join-Path $d3 '.stride/.stop-gate-blocks') -Force -ErrorAction SilentlyContinue
            & chmod 555 (Join-Path $d3 '.stride') 2>$null
            $r = Invoke-G19Gate -Cwd $d3
            & chmod 755 (Join-Path $d3 '.stride') 2>$null
            Assert-Eq "19h4: an unwritable .stride permits" "" $r.Stdout.Trim()
            Assert-Contains "19h4: and says the block could not be bounded" 'cannot be bounded' $r.Stderr
        }

        # 19aa: stdout discipline, structurally — PowerShell's IMPLICIT PIPELINE
        # OUTPUT is the live hazard on this half, so these are asserted over the
        # source with comments stripped (the header names each guard in prose).
        $g19Src = (Get-Content -LiteralPath $G19Gate) | Where-Object { $_ -notmatch '^\s*#' }
        Assert-Eq "19aa: exactly one Write-Output in the gate" "1" `
            ([string](@($g19Src | Where-Object { $_ -match 'Write-Output' })).Count)
        Assert-Eq "19aa: zero Write-Host / Write-Information / Write-Verbose" "0" `
            ([string](@($g19Src | Where-Object { $_ -match 'Write-Host|Write-Information|Write-Verbose' })).Count)
        Assert-Eq "19aa: no CODE path exits 2" "0" `
            ([string](@($g19Src | Where-Object { $_ -match 'exit 2' })).Count)
        Assert-Eq "19aa: New-Item is piped to Out-Null" "0" `
            ([string](@($g19Src | Where-Object { $_ -match 'New-Item' -and $_ -notmatch 'Out-Null' })).Count)
        Assert-Eq "19aa: Set-Content never uses -PassThru" "0" `
            ([string](@($g19Src | Where-Object { $_ -match 'Set-Content' -and $_ -match '-PassThru' })).Count)

        # 19ah: cross-half parity of the permit reasons, byte for byte. The two
        # halves must not drift by eye. The needs-review permit needs no network.
        $g19Bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $g19Bash) {
            Write-Host "  SKIP: 19ah (cross-half reason parity - bash is not available)"
        } else {
            $d = New-G19Project 'ah' -Url $G19Url; Set-G19State -Dir $d -Ident 'W2147' -NeedsReview $true
            $psErr = (Invoke-G19Gate -Cwd $d).Stderr
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = 'bash'
            $psi.Arguments = "`"$G19GateSh`""
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Write("{`"cwd`":`"$d`"}")
            $p.StandardInput.Close()
            $null = $p.StandardOutput.ReadToEnd()
            $shErr = $p.StandardError.ReadToEnd()
            $p.WaitForExit()
            Assert-Eq "19ah: both halves report the needs-review permit identically" $shErr.Trim() $psErr.Trim()
        }
    }
} finally {
    Remove-Job $G19Job -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "========================================"
$Total = $script:PASS + $script:FAIL
Write-Host "Results: $($script:PASS) passed, $($script:FAIL) failed (out of $Total)"
Write-Host "========================================"

} finally {
    # Cleanup
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}

if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
