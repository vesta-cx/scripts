#!/usr/bin/env bash
# Push each subtree from the monorepo back to its respective remote.
# Run from the vesta monorepo root. Reads .gittrees for prefix and URL.
# Usage: ./tools/scripts/push-subtrees.sh [branch]
#   branch defaults to main.

set -e

GITROOT="$(git rev-parse --show-toplevel)"
GITTREES="${GITROOT}/.gittrees"
BRANCH="${1:-main}"

if [[ ! -f "$GITTREES" ]]; then
  echo "Missing .gittrees at repo root." >&2
  exit 1
fi

cd "$GITROOT"
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^#.*$ ]] && continue
  [[ -z "${line// /}" ]] && continue
  prefix="${line%%$'\t'*}"
  url="${line#*$'\t'}"
  [[ -z "$prefix" || -z "$url" ]] && continue
  echo "Pushing subtree prefix=$prefix to $url (branch $BRANCH)"
  git subtree push --prefix="$prefix" "$url" "$BRANCH"
done < "$GITTREES"

echo "Done."
