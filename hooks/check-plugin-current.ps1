# check-plugin-current.ps1 — is this stride-copilot install behind the catalog?
# PowerShell twin of check-plugin-current.sh (W2539, port of stride W2251).
# The two halves behave the same; change one, change both.
#
# Copilot CLI loads every skill and custom agent from the installed copy of the
# plugin, and a claim reports skills_version "1.0" whatever the release, so a
# copy that has fallen behind the published one is invisible to the server.
# This script makes it visible, and does nothing else.
#
# INPUTS (no parameters; any arguments are ignored)
#   ours:      the "version" string in plugin.json one directory above this
#              script's hooks\ folder, i.e. the plugin root, from a manifest
#              whose "name" is exactly "stride-copilot". Copilot CLI documents
#              a plugin-root variable for MCP and LSP servers only, never for
#              skills, so the root comes from $PSScriptRoot.
#   catalog:   the "version" of the FIRST plugins[] entry whose name is exactly
#              "stride-copilot" in the stride-copilot-marketplace catalog,
#              fetched once over HTTPS. A later duplicate entry is never
#              consulted, any status outside 2xx counts as no catalog, and a
#              redirect is never followed. The bash half (curl --fail) differs
#              only on a 3xx, whose body it reads but which is never a catalog.
#
# OUTPUT: one line, only when ours is lower than the catalog's, carrying both
# numbers and `copilot plugin update stride-copilot`. Silent otherwise — the
# same or a higher version, no readable manifest, a version that is not plain
# dotted digits (pre-release, v-prefixed and "latest" all count as unknown), a
# failed or slow fetch, a body not in the catalog's shape, or no stride-copilot
# entry. EXIT STATUS is 0 on every path.
#
# SAFETY: the catalog address is a constant here and nothing passed in changes
# it. The request goes through HttpClient with redirects, cookies and default
# credentials all switched off and no Authorization header. The body only ever
# goes through ConvertFrom-Json; it is never evaluated. Only text that matched the
# anchored digits-and-dots pattern reaches stdout. The pattern ends in \z, not
# $, because a .NET $ also matches just before a trailing newline.
#
# TIMEOUT: HttpClient.Timeout = 3 seconds bounds the connection, the response
# headers and the full body together, since GetAsync buffers the body before
# it returns. Invoke-WebRequest is avoided on purpose: on several releases its
# -TimeoutSec no longer applies once the headers have landed. The bash half has
# two bounds (2s connect, 3s total) where this one has a single 3s bound.
#
# NEWLINES: bash's $(...) strips trailing LFs from a value, so this half strips
# them too (ConvertTo-StrideBashValue) and both read "2.42.0\n" as 2.42.0. A CR
# or an interior newline is left in place for the pattern to refuse.
#
# TESTING: dot-sourcing this file defines its functions and stops there, so
# test-stride-hook.ps1 can replace Get-StridePinBody or Invoke-StridePinRequest
# in a child scope instead of making the URL an input.

Set-StrictMode -Version Latest

$script:StrideCopilotPinUrl = 'https://raw.githubusercontent.com/cheezy/stride-copilot-marketplace/main/.github/plugin/marketplace.json'
$script:StrideCopilotUpdateCmd = 'copilot plugin update stride-copilot'
$script:StrideCopilotVersionRe = '^[0-9]+(\.[0-9]+)*\z'
$script:StrideCopilotPluginRoot = ''
if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
    $script:StrideCopilotPluginRoot = Split-Path -Parent $PSScriptRoot
}

# Parse JSON while stopping PowerShell 7 from replacing a single-item array
# with its lone element; 5.1 lacks -NoEnumerate and never does that anyway.
function ConvertFrom-StrideJson {
    param([string]$Text)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')) {
        return , ($Text | ConvertFrom-Json -NoEnumerate -ErrorAction Stop)
    }
    return , ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function Test-StrideVersionShape {
    param([string]$Version)
    if ([string]::IsNullOrEmpty($Version)) { return $false }
    return ($Version -cmatch $script:StrideCopilotVersionRe)
}

# Drop trailing LFs only, matching what command substitution does in bash.
function ConvertTo-StrideBashValue {
    param([string]$Value)
    return $Value.TrimEnd([char]10)
}

# Our version from <Root>\plugin.json, or ''.
function Get-StrideInstalledVersion {
    param([string]$Root)
    if ([string]::IsNullOrEmpty($Root)) { return '' }
    try {
        $manifest = Join-Path $Root 'plugin.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return '' }
        $parsed = ConvertFrom-StrideJson (Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop)
        if ($parsed -isnot [System.Management.Automation.PSCustomObject]) { return '' }
        if ($parsed.PSObject.Properties.Match('name').Count -eq 0) { return '' }
        if ($parsed.name -isnot [string] -or $parsed.name -cne 'stride-copilot') { return '' }
        if ($parsed.PSObject.Properties.Match('version').Count -gt 0 -and $parsed.version -is [string]) {
            return (ConvertTo-StrideBashValue $parsed.version)
        }
    } catch {
        return ''
    }
    return ''
}

# One anonymous GET of the catalog within one 3-second limit. Throws on
# a transport failure; returns '' for a non-success status.
function Invoke-StridePinRequest {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = New-Object System.Net.Http.HttpClient -ArgumentList $handler
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(3)
        $null = $client.DefaultRequestHeaders.UserAgent.TryParseAdd('curl/stride-copilot-check')
        $resp = $client.GetAsync($script:StrideCopilotPinUrl).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { return '' }
        return [string]$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        $client.Dispose()
    }
}

# The catalog text, or '' on any failure. The test suite replaces this.
function Get-StridePinBody {
    try {
        return [string](Invoke-StridePinRequest)
    } catch {
        return ''
    }
}

# The stride-copilot entry's version from catalog text, or ''.
function Get-StridePublishedVersion {
    param([string]$Body)
    if ([string]::IsNullOrEmpty($Body)) { return '' }
    try {
        $catalog = ConvertFrom-StrideJson $Body
        if ($catalog -isnot [System.Management.Automation.PSCustomObject]) { return '' }
        if ($catalog.PSObject.Properties.Match('plugins').Count -eq 0) { return '' }
        $plugins = $catalog.plugins
        if ($plugins -isnot [array]) { return '' }
        foreach ($entry in $plugins) {
            if ($entry -isnot [System.Management.Automation.PSCustomObject]) { continue }
            if ($entry.PSObject.Properties.Match('name').Count -eq 0) { continue }
            if ($entry.name -isnot [string] -or $entry.name -cne 'stride-copilot') { continue }
            if ($entry.PSObject.Properties.Match('version').Count -gt 0 -and $entry.version -is [string]) {
                return (ConvertTo-StrideBashValue $entry.version)
            }
            return ''
        }
    } catch {
        return ''
    }
    return ''
}

# $true only when $Older is strictly lower than $Newer; both already match the
# version pattern. A part longer than 18 digits is unknown, as in bash.
function Test-StrideVersionOlder {
    param([string]$Older, [string]$Newer)
    $aParts = $Older.Split('.')
    $bParts = $Newer.Split('.')
    $n = [Math]::Max($aParts.Count, $bParts.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $pa = '0'
        $pb = '0'
        if ($i -lt $aParts.Count) { $pa = $aParts[$i] }
        if ($i -lt $bParts.Count) { $pb = $bParts[$i] }
        if ($pa.Length -gt 18 -or $pb.Length -gt 18) { return $false }
        $x = [decimal]::Parse($pa, [System.Globalization.CultureInfo]::InvariantCulture)
        $y = [decimal]::Parse($pb, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($x -lt $y) { return $true }
        if ($x -gt $y) { return $false }
    }
    return $false
}

function Invoke-StridePluginCheck {
    param([string]$Root)
    $installed = Get-StrideInstalledVersion $Root
    if (-not (Test-StrideVersionShape $installed)) { return }
    $published = Get-StridePublishedVersion (Get-StridePinBody)
    if (-not (Test-StrideVersionShape $published)) { return }
    $older = $false
    try { $older = Test-StrideVersionOlder $installed $published } catch { return }
    if ($older) {
        Write-Output ("stride-copilot {0} is installed, but stride-copilot-marketplace now pins {1}. Update it with: {2}" -f $installed, $published, $script:StrideCopilotUpdateCmd)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-StridePluginCheck $script:StrideCopilotPluginRoot } catch { $null = $_ }
    exit 0
}
