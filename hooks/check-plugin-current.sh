#!/usr/bin/env bash
# check-plugin-current.sh — is this stride-copilot install behind the catalog?
# Run once per session from stride-workflow Step 0 (W2539, port of stride W2251).
#
# Copilot CLI loads every skill and custom agent from the installed copy of the
# plugin, and a claim reports skills_version "1.0" whatever the release, so a
# copy that has fallen behind the published one is invisible to the server.
# This script makes it visible, and does nothing else.
#
# INPUTS (no arguments; any that are given are ignored)
#   ours:      the "version" string in plugin.json one directory above this
#              script's hooks/ folder, i.e. the plugin root. The manifest must
#              also say "name": "stride-copilot", so a stray copy of the script
#              beside some other plugin's manifest stays quiet. Copilot CLI
#              documents a plugin-root variable for MCP and LSP servers only,
#              never for skills, which is why the script finds the root from
#              its own path instead of being told it.
#   catalog:   the "version" of the FIRST plugins[] entry whose name is exactly
#              "stride-copilot" in the stride-copilot-marketplace catalog,
#              fetched once over HTTPS. A later duplicate entry is never
#              consulted, an HTTP error status (4xx or 5xx, curl --fail)
#              counts as no catalog, and a redirect is never followed.
#
# OUTPUT
#   One line, and only when ours is lower than the catalog's, carrying both
#   numbers and the command `copilot plugin update stride-copilot`. Anything
#   else stays silent: the same or a higher version, no readable manifest, a
#   version that is not plain dotted digits (so 2.43.0-rc.1, v2.43.0 and
#   "latest" all count as unknown), no curl or jq, a failed or slow fetch, a
#   body that does not parse into the catalog's shape, or no stride-copilot
#   entry in it. Unknown never turns into a guess.
#
# EXIT STATUS is 0 on every path. The line is advice for the user; it never
# holds up the workflow.
#
# SAFETY
#   - The catalog address is a constant in this file, not an input.
#   - The fetch is anonymous: it carries no Authorization header and no token,
#     cookie or netrc login. -q is the first curl argument so a ~/.curlrc cannot add any of
#     those, or a redirect, behind our back. Redirects are never followed.
#   - It is bounded: 2 seconds to connect, 3 seconds in total.
#   - jq treats the body as data; it is never run or sourced. Nothing
#     reaches stdout unless it first matched VERSION_RE, which is anchored at
#     both ends and admits digits and dots only — so catalog text cannot put
#     escape sequences or prose on the user's terminal.
#
# COMPARISON is part by part as integers (2.10.0 is newer than 2.9.0) and an
# absent part is taken as 0 (2.42 equals 2.42.0). A part longer than 18 digits
# would overflow bash arithmetic, so it is treated as unknown.
#
# Beyond bash itself it uses curl and jq and nothing else: no pipes, no eval.

set -u

PIN_URL="https://raw.githubusercontent.com/cheezy/stride-copilot-marketplace/main/.github/plugin/marketplace.json"
UPDATE_CMD="copilot plugin update stride-copilot"
VERSION_RE='^[0-9]+(\.[0-9]+)*$'

# Where plugin.json is expected: the parent of the directory holding this
# script. Worked out with parameter expansion, so dirname is not needed.
manifest_path() {
  _src="${BASH_SOURCE[0]:-$0}"
  case "$_src" in
    */*) _dir="${_src%/*}" ;;
    *) _dir="." ;;
  esac
  printf '%s' "$_dir/../plugin.json"
}

# Print our version from the manifest file named by $1, if it has a usable one.
installed_version() {
  jq -r 'if type == "object" and .name == "stride-copilot" and (.version | type) == "string" then .version else empty end' "$1" 2> /dev/null
}

# Read catalog JSON from stdin; print the stride-copilot entry's version if any.
published_version() {
  jq -r 'if type == "object" and (.plugins | type) == "array" then ((first(.plugins[] | select(type == "object" and .name == "stride-copilot")) | .version | select(type == "string")) // empty) else empty end' 2> /dev/null
}

# Succeed only when $1 is strictly lower than $2. Both already match VERSION_RE.
version_older() {
  IFS=. read -r -a _a_parts <<< "$1"
  IFS=. read -r -a _b_parts <<< "$2"
  _n=${#_a_parts[@]}
  [ "${#_b_parts[@]}" -gt "$_n" ] && _n=${#_b_parts[@]}
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _pa="${_a_parts[$_i]:-0}"
    _pb="${_b_parts[$_i]:-0}"
    # Too long to compare safely: unknown, so no claim either way.
    [ "${#_pa}" -gt 18 ] && return 1
    [ "${#_pb}" -gt 18 ] && return 1
    _x=$(( 10#$_pa ))
    _y=$(( 10#$_pb ))
    [ "$_x" -lt "$_y" ] && return 0
    [ "$_x" -gt "$_y" ] && return 1
    _i=$(( _i + 1 ))
  done
  return 1
}

main() {
  command -v jq > /dev/null 2>&1 || return 0
  # A missing, unreadable or malformed manifest makes jq yield nothing.
  _installed="$(installed_version "$(manifest_path)")"
  [[ "$_installed" =~ $VERSION_RE ]] || return 0
  command -v curl > /dev/null 2>&1 || return 0
  _body="$(curl -q -fsS --proto '=https' --connect-timeout 2 --max-time 3 -A 'curl/stride-copilot-check' "$PIN_URL" 2> /dev/null)" || return 0
  [ -n "$_body" ] || return 0
  _published="$(published_version <<< "$_body")"
  [[ "$_published" =~ $VERSION_RE ]] || return 0
  if version_older "$_installed" "$_published"; then
    printf 'stride-copilot %s is installed, but stride-copilot-marketplace now pins %s. Update it with: %s\n' \
      "$_installed" "$_published" "$UPDATE_CMD"
  fi
  return 0
}

main "$@"
exit 0
