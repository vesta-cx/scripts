#!/usr/bin/env bash
# Add git subtrees from .gittrees one at a time: fetch then add (no chaining refs).
# Works from any working directory. Run from monorepo root or below.
#
# Usage: ./tools/scripts/add-subtrees.sh [prefix ...]
#   No args: add all entries from .gittrees that are not already present.
#   With prefixes: add only those (e.g. ./add-subtrees.sh apps/euterpe packages/db).
#
# For each subtree: ensure remote exists, fetch <remote> <branch>, then
# git subtree add --prefix=<path> <remote> <branch>. One fetch per add so ref is correct.

set -e

GITROOT="$(git rev-parse --show-toplevel)"
GITTREES="${GITROOT}/.gittrees"
WANTED=("$@")

if [[ ! -f "$GITTREES" ]]; then
  echo "Missing .gittrees at repo root." >&2
  exit 1
fi

do_add() {
  if [[ -z "$path" || -z "$remote" ]]; then
    return
  fi
  local branch="${branch:-main}"

  if [[ ${#WANTED[@]} -gt 0 ]]; then
    local found=0
    for w in "${WANTED[@]}"; do
      [[ "$w" == "$path" ]] && { found=1; break; }
    done
    [[ $found -eq 0 ]] && return
  fi

  if [[ -d "$GITROOT/$path" ]] && git ls-files --error-unmatch "$path" &>/dev/null; then
    echo "Skipping $path (already present)."
    return
  fi

  if ! git config --get "remote.${remote}.url" &>/dev/null; then
    if [[ -n "$url" ]]; then
      echo "Adding remote $remote ($url)"
      git remote add "$remote" "$url"
    else
      echo "remote \"${remote}\" for subtree \"${path}\" does not exist and no url in .gittrees" >&2
      FAILED=1
      return
    fi
  fi

  echo "Fetching $remote $branch..."
  git fetch "$remote" "$branch"
  echo "Adding subtree prefix=$path from $remote $branch"
  if ! git subtree add --prefix="$path" "$remote" "$branch"; then
    FAILED=1
  fi
}

path=""
remote=""
url=""
branch=""
FAILED=0

cd "$GITROOT"
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue

  if [[ "$line" =~ ^[[:space:]]*\[subtree ]]; then
    do_add
    path=""
    remote=""
    url=""
    branch=""
    continue
  fi

  if [[ "$line" =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*) ]]; then
    path="$(echo "${BASH_REMATCH[1]}" | xargs)"
    path="${path#\"}"; path="${path%\"}"
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]*remote[[:space:]]*=[[:space:]]*(.*) ]]; then
    remote="$(echo "${BASH_REMATCH[1]}" | xargs)"
    remote="${remote#\"}"; remote="${remote%\"}"
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]*url[[:space:]]*=[[:space:]]*(.*) ]]; then
    url="$(echo "${BASH_REMATCH[1]}" | xargs)"
    url="${url#\"}"; url="${url%\"}"
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]*branch[[:space:]]*=[[:space:]]*(.*) ]]; then
    branch="$(echo "${BASH_REMATCH[1]}" | xargs)"
    branch="${branch#\"}"; branch="${branch%\"}"
    continue
  fi
done < "$GITTREES"

do_add

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more subtree adds failed." >&2
  exit 1
fi
echo "Done."
