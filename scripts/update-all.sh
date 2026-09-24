#!/usr/bin/env bash
#
# update-all.sh — safely bring every managed repo up to latest origin/main.
#
# For each repo in repos.txt that is checked out here:
#   1. fetch --prune
#   2. if the working tree is dirty, PAUSE and ask: stash / skip / quit
#      (non-interactive shells auto-skip dirty repos; override with a flag)
#   3. if on main  -> git pull --ff-only origin main
#      if on branch -> fast-forward local main (main:main), leave your branch alone
#
# Usage: scripts/update-all.sh [--stash-all] [--skip-dirty] [--dry-run]
#   --stash-all   don't prompt; always stash dirty repos, then update
#   --skip-dirty  don't prompt; always skip dirty repos
#   --dry-run     show what would happen, change nothing
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STASH_ALL=false SKIP_DIRTY=false DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --stash-all)  STASH_ALL=true ;;
    --skip-dirty) SKIP_DIRTY=true ;;
    --dry-run)    DRY_RUN=true ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Unknown argument: $arg"; exit 2 ;;
  esac
done

cd "$WORKSPACE_ROOT"

updated=0 current=0 on_feature=0 stashed=0 skipped=0 missing=0 failed=0
stashed_repos=() skipped_repos=() failed_repos=()

# Decide what to do about a dirty repo. Echoes: stash | skip | quit
resolve_dirty() {
  local name="$1"
  if $STASH_ALL; then echo stash; return; fi
  if $SKIP_DIRTY; then echo skip; return; fi
  if ! is_tty; then
    warn "  $name has uncommitted changes; skipping (non-interactive)."
    echo skip; return
  fi
  local reply
  while true; do
    printf '%s' "${_c_ylw}  $name has uncommitted changes — [s]tash & update, s[k]ip, [q]uit? ${_c_reset}" >&2
    read -r reply
    case "$reply" in
      s|S) echo stash; return ;;
      k|K) echo skip;  return ;;
      q|Q) echo quit;  return ;;
      *)   warn "  please answer s, k, or q." ;;
    esac
  done
}

# Fast-forward a repo already on a clean checkout. Echoes a status word.
do_update() {
  local name="$1" branch="$2"
  if [ "$branch" = "main" ]; then
    if git -C "$name" pull --ff-only --quiet origin main; then
      echo updated
    else
      echo failed
    fi
  else
    # Update local main without leaving the current branch.
    if git -C "$name" fetch --quiet origin main:main 2>/dev/null; then
      echo on_feature
    else
      # Either already up to date, or diverged — distinguish for the user.
      echo on_feature_nff
    fi
  fi
}

while IFS=$'\t' read -r name url; do
  [ -z "$name" ] && continue
  if [ ! -d "$name/.git" ]; then
    warn "  missing  $name (run clone-all.sh)"
    missing=$((missing + 1))
    continue
  fi

  if $DRY_RUN; then
    branch="$(git -C "$name" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    dirty=""
    [ -n "$(git -C "$name" status --porcelain)" ] && dirty=" (dirty)"
    info "  would update  $name  [on ${branch}]${dirty}"
    continue
  fi

  git -C "$name" fetch --prune --quiet origin || { err "  fetch failed: $name"; failed=$((failed+1)); failed_repos+=("$name"); continue; }

  branch="$(git -C "$name" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'HEAD')"

  # Handle a dirty working tree before touching anything.
  if [ -n "$(git -C "$name" status --porcelain)" ]; then
    case "$(resolve_dirty "$name")" in
      quit)
        warn "Stopping at user request."
        break
        ;;
      skip)
        dim "  skipped  $name (left as-is)"
        skipped=$((skipped + 1)); skipped_repos+=("$name")
        continue
        ;;
      stash)
        if git -C "$name" stash push --include-untracked --quiet -m "update-all $(date +%Y-%m-%dT%H:%M:%S)"; then
          stashed=$((stashed + 1)); stashed_repos+=("$name")
        else
          err "  stash failed: $name — skipping"
          failed=$((failed + 1)); failed_repos+=("$name"); continue
        fi
        ;;
    esac
  fi

  case "$(do_update "$name" "$branch")" in
    updated)
      ok "  updated  $name"
      updated=$((updated + 1)) ;;
    on_feature)
      ok "  on ${branch}; main fast-forwarded  $name"
      on_feature=$((on_feature + 1)) ;;
    on_feature_nff)
      warn "  on ${branch}; main NOT updated (up to date or diverged)  $name"
      on_feature=$((on_feature + 1)) ;;
    failed)
      err "  pull failed (not fast-forward?)  $name"
      failed=$((failed + 1)); failed_repos+=("$name") ;;
  esac
done < <(manifest_repos)

echo
ok "Summary: ${updated} updated, ${on_feature} on feature branch, ${current} already current."
[ "$missing" -gt 0 ] && warn "  ${missing} missing (run clone-all.sh)"
if [ "$stashed" -gt 0 ]; then
  warn "  ${stashed} stashed — recover with 'git -C <repo> stash pop': ${stashed_repos[*]}"
fi
[ "$skipped" -gt 0 ] && dim "  ${skipped} skipped: ${skipped_repos[*]}"
if [ "$failed" -gt 0 ]; then
  err "  ${failed} failed: ${failed_repos[*]}"
  exit 1
fi
