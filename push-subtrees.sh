#!/usr/bin/env bash
# 1. Run normal git push with any passed arguments.
# 2. If .gittrees exists at monorepo root, push each listed subtree to its remote.
# Works from any working directory (resolves monorepo root first).
# Usage: ./tools/scripts/push-subtrees.sh [git-push args...]
#   e.g. ./tools/scripts/push-subtrees.sh
#        ./tools/scripts/push-subtrees.sh origin main

set -e

GITROOT="$(git rev-parse --show-toplevel)"
GITTREES="${GITROOT}/.gittrees"

# 1. If no .gittrees at repo root, only run normal push and exit.
if [[ ! -f "$GITTREES" ]]; then
  exec git push "$@"
fi

# 2. Run normal push (pass through all arguments).
git push "$@"

# 3. Parse .gittrees: [subtree "name"], path = ..., remote = ..., url = ..., branch = ...
do_push() {
  if [[ -z "$path" || -z "$remote" ]]; then
    return
  fi
  local branch="${branch:-main}"
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
  echo "Pushing subtree prefix=$path to remote $remote (branch $branch)"
  if ! git subtree push --prefix="$path" "$remote" "$branch"; then
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
    do_push
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

do_push

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more subtree pushes failed." >&2
  exit 1
fi
echo "Done."
