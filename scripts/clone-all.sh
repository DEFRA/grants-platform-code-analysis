#!/usr/bin/env bash
#
# clone-all.sh — ensure every repo listed in repos.txt is checked out here.
#
# Idempotent bootstrap: clones any missing repo, leaves existing ones untouched.
# Use update-all.sh to bring existing checkouts up to date.
#
# Usage: scripts/clone-all.sh [--dry-run]
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown argument: $arg"; exit 2 ;;
  esac
done

cd "$WORKSPACE_ROOT"

cloned=0 present=0 failed=0
failures=()

while IFS=$'\t' read -r name url; do
  [ -z "$name" ] && continue
  if [ -d "$name/.git" ]; then
    dim "  present  $name"
    present=$((present + 1))
    continue
  fi
  if [ -e "$name" ]; then
    warn "  exists (not a git repo), skipping: $name"
    failed=$((failed + 1)); failures+=("$name")
    continue
  fi
  if $DRY_RUN; then
    info "  would clone  $name  <-  $url"
    cloned=$((cloned + 1))
    continue
  fi
  info "  cloning  $name ..."
  if git clone --quiet "$url" "$name"; then
    ok "  cloned   $name"
    cloned=$((cloned + 1))
  else
    err "  FAILED   $name  ($url)"
    failed=$((failed + 1)); failures+=("$name")
  fi
done < <(manifest_repos)

echo
if $DRY_RUN; then
  info "Dry run: would clone ${cloned}, ${present} already present."
else
  ok "Done: cloned ${cloned}, ${present} already present, ${failed} failed."
fi
if [ "$failed" -gt 0 ]; then
  err "Failed: ${failures[*]}"
  exit 1
fi
