#!/usr/bin/env bash
# Sync every repository in repos.txt. One failure does not stop the others.
# Exit 0 only if every repository synced or was already current.
#
#   SRC_BASE=... DST_BASE=... SRC_TOKEN=... DST_TOKEN=... ./sync.sh
#
# Inputs (environment): the inputs of sync-repo.sh, and
#   REPOS_FILE    optional. Default repos.txt next to this script.
#   SYNC_TIMEOUT  optional. Seconds one repository may take. Default 120. The loop's RUN_DEADLINE
#                 must cover every repository: count x (timeout + 10).
#
# The output of git passes through a filter that hides the two tokens. git does
# not print them. The filter is a second line of defence.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "sync: $*" >&2; exit 2; }

# A traced shell would print both tokens.
case "$-" in *x*) fail "shell tracing is on. Stopping before this script prints a token." ;; esac
: "${SRC_TOKEN:?set SRC_TOKEN}" "${DST_TOKEN:?set DST_TOKEN}"
[ "$SRC_TOKEN" != "$DST_TOKEN" ] || fail "SRC_TOKEN and DST_TOKEN are the same value"

repos_file="${REPOS_FILE:-$here/repos.txt}"
timeout_s="${SYNC_TIMEOUT:-120}"
[[ "$timeout_s" =~ ^[0-9]+$ ]] || fail "SYNC_TIMEOUT must be a number of seconds"

mapfile -t repos < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$repos_file")
[ "${#repos[@]}" -gt 0 ] || fail "$repos_file lists no repository"
if [ -n "$(printf '%s\n' "${repos[@]}" | sort | uniq -d)" ]; then fail "$repos_file lists a repository twice"; fi

redact() {
  awk 'BEGIN { s = ENVIRON["SRC_TOKEN"]; d = ENVIRON["DST_TOKEN"] }
    { line = $0
      if (s != "") while ((i = index(line, s)) > 0) line = substr(line, 1, i - 1) "[hidden]" substr(line, i + length(s))
      if (d != "") while ((i = index(line, d)) > 0) line = substr(line, 1, i - 1) "[hidden]" substr(line, i + length(d))
      print line }'
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

synced=0 unchanged=0 failed=()
for name in "${repos[@]}"; do
  out="$work/$name.out"
  if timeout --kill-after=10 "$timeout_s" "$here/sync-repo.sh" "$name" "$work/$name.git" >"$out" 2>&1; then
    result="$(tail -n 1 "$out")"
    if [ "$result" = unchanged ]; then unchanged=$((unchanged + 1)); else synced=$((synced + 1)); fi
    echo "ok: $name ($result)"
  else
    code=$?
    failed+=("$name")
    reason="$(tail -n 5 "$out" | redact)"
    [ "$code" -ne 124 ] || reason="timed out after $timeout_s seconds"
    echo "FAILED: $name"
    printf '%s\n' "$reason" | sed 's/^/    /'
  fi
done

echo
echo "${#repos[@]} repositories: $synced synced, $unchanged unchanged, ${#failed[@]} failed"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "failed: ${failed[*]}"
  exit 1
fi
