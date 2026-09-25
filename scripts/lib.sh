#!/usr/bin/env bash
# Shared helpers for the workspace scripts. Source this; do not run directly.

# Workspace root = the directory containing this scripts/ dir = the git repo root.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${_lib_dir}/.." && pwd)"
MANIFEST="${WORKSPACE_ROOT}/repos.txt"

# --- logging -----------------------------------------------------------------
# Colour only when stdout is a terminal, so piped/CI output stays clean.
if [ -t 1 ]; then
  _c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'
  _c_ylw=$'\033[33m'; _c_blu=$'\033[34m'; _c_dim=$'\033[2m'
else
  _c_reset=''; _c_red=''; _c_grn=''; _c_ylw=''; _c_blu=''; _c_dim=''
fi

info()  { printf '%s\n' "${_c_blu}${*}${_c_reset}"; }
ok()    { printf '%s\n' "${_c_grn}${*}${_c_reset}"; }
warn()  { printf '%s\n' "${_c_ylw}${*}${_c_reset}" >&2; }
err()   { printf '%s\n' "${_c_red}${*}${_c_reset}" >&2; }
dim()   { printf '%s\n' "${_c_dim}${*}${_c_reset}"; }

is_tty() { [ -t 0 ] && [ -t 1 ]; }

# --- manifest parsing --------------------------------------------------------
# Emit one "name<TAB>clone_url" line per repo in repos.txt.
# Honours a leading '# org=<name>' directive for bare names.
# Pass "true" as the first argument to use HTTPS instead of SSH for bare names.
manifest_repos() {
  local use_https="${1:-false}"
  if [ ! -f "$MANIFEST" ]; then
    err "Manifest not found: $MANIFEST"
    return 1
  fi
  local org="DEFRA" line name url
  while IFS= read -r line || [ -n "$line" ]; do
    # Capture '# org=...' before stripping comments.
    if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*org=([A-Za-z0-9._-]+) ]]; then
      org="${BASH_REMATCH[1]}"
      continue
    fi
    line="${line%%#*}"                       # strip trailing comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [ -z "$line" ] && continue

    if [[ "$line" == *://* || "$line" == *@*:* ]]; then
      url="$line"
      name="$(basename "$line")"; name="${name%.git}"
    else
      name="$line"
      if [ "$use_https" = "true" ]; then
        url="https://github.com/${org}/${name}.git"
      else
        url="git@github.com:${org}/${name}.git"
      fi
    fi
    printf '%s\t%s\n' "$name" "$url"
  done < "$MANIFEST"
}
