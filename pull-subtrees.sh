#!/usr/bin/env bash
# If .gittrees exists at monorepo root, pull each listed subtree from its remote.
# Works from any working directory (resolves monorepo root first).
# Usage: ./tools/scripts/pull-subtrees.sh [git-pull args...]
#   With no args: only subtree pulls. With args (e.g. origin main): run git pull first, then subtree pulls.

set -e

GITROOT="$(git rev-parse --show-toplevel)"
GITTREES="${GITROOT}/.gittrees"

if [[ ! -f "$GITTREES" ]]; then
  exec git pull "$@"
fi

if [[ $# -gt 0 ]]; then
  git pull "$@"
fi

# Parse .gittrees: [subtree "name"], path = ..., remote = ..., url = ..., branch = ...
do_pull() {
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
  echo "Pulling subtree prefix=$path from remote $remote (branch $branch)"
  set +e
  err="$(git subtree pull --prefix="$path" "$remote" "$branch" 2>&1)"
  subtree_exit=$?
  set -e
  if [[ $subtree_exit -ne 0 ]]; then
    if [[ "$err" == *"refusing to merge unrelated histories"* ]]; then
      echo "  -> Unrelated histories; merging with --allow-unrelated-histories"
      git fetch "$remote" "$branch"
      if ! git merge -s subtree -X subtree="$path" --allow-unrelated-histories FETCH_HEAD -m "Merge $remote/$branch into $path (allow unrelated histories)"; then
        echo "  -> Merge failed (conflicts?). Resolve and commit, then re-run." >&2
        FAILED=1
      fi
    else
      echo "$err" >&2
      FAILED=1
    fi
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
    do_pull
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

do_pull

if [[ "$FAILED" -ne 0 ]]; then
  echo "One or more subtree pulls failed." >&2
  exit 1
fi
echo "Done."
