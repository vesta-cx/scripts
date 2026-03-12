#!/usr/bin/env bash
# Push each subtree from the monorepo back to its respective remote.
# Run from the vesta monorepo root. Reads .gittrees (TOML, same shape as .gitmodules).
# Usage: ./tools/scripts/push-subtrees.sh [branch]
#   branch defaults to main; per-subtree branch in .gittrees overrides when set.

set -e

GITROOT="$(git rev-parse --show-toplevel)"
GITTREES="${GITROOT}/.gittrees"
DEFAULT_BRANCH="${1:-main}"

if [[ ! -f "$GITTREES" ]]; then
  echo "Missing .gittrees at repo root." >&2
  exit 1
fi

# Parse TOML-like .gittrees: [subtree "name"], path = ..., url = ..., branch = ...
do_push() {
  if [[ -n "$path" && -n "$url" ]]; then
    local branch="${branch:-$DEFAULT_BRANCH}"
    echo "Pushing subtree prefix=$path to $url (branch $branch)"
    git subtree push --prefix="$path" "$url" "$branch"
  fi
}

path=""
url=""
branch=""

cd "$GITROOT"
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue

  if [[ "$line" =~ ^[[:space:]]*\[subtree ]]; then
    do_push
    path=""
    url=""
    branch=""
    continue
  fi

  if [[ "$line" =~ ^[[:space:]]*path[[:space:]]*=[[:space:]]*(.*) ]]; then
    path="$(echo "${BASH_REMATCH[1]}" | xargs)"
    path="${path#\"}"; path="${path%\"}"
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

do_push
echo "Done."
