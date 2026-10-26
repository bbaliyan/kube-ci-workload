#!/usr/bin/env bash
# Tests for the mirror sync in apps/mirror-sync: sync-repo.sh, sync.sh, askpass.sh, loop.sh and
# the Deployment it renders. Two small authenticated git servers stand in for GitHub and GitLab.
# Run: tests/mirror-sync.sh
# shellcheck disable=SC2319 # "$?" right after a test command is the point of the is() helper
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
dir="$repo/apps/mirror-sync/files"
server="$repo/tests/fixtures/git-http-server.py"
work="$(mktemp -d)"
pids=()
cleanup() {
  [ "${#pids[@]}" -eq 0 ] || kill "${pids[@]}" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT
failures=0

for tool in git python3; do
  command -v "$tool" >/dev/null || { echo "tests/mirror-sync.sh needs $tool (it is in the kube-devenv image)" >&2; exit 2; }
done

report() { # name, ok or the reason
  if [ "$2" = ok ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; failures=$((failures + 1)); fi
}
is() { # name, condition result (0 = pass), detail
  if [ "$2" -eq 0 ]; then report "$1" ok; else report "$1" "${3:-failed}"; fi
}

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
src_token=ghp_SourceTokenValue111
dst_token=glpat-MirrorTokenValue222

# ---- two servers ------------------------------------------------------------
mkdir -p "$work/src" "$work/dst"
printf '%s\n' "$src_token" >"$work/src.token"
printf '%s\n' "$dst_token" >"$work/dst.token"
for side in src dst; do
  python3 -I "$server" "$work/$side" "$work/$side.token" "$work/$side.log" "$work/$side.port" &
  pids+=($!)
done
for _ in $(seq 1 50); do
  [ -s "$work/src.port" ] && [ -s "$work/dst.port" ] && break
  sleep 0.1
done
[ -s "$work/src.port" ] && [ -s "$work/dst.port" ] || { echo "the test servers did not start" >&2; exit 2; }
src_base="http://127.0.0.1:$(cat "$work/src.port")"
dst_base="http://127.0.0.1:$(cat "$work/dst.port")"

# ---- repositories -------------------------------------------------------------
commit() { # worktree, message: an empty commit
  git -C "$1" commit --quiet --allow-empty -m "$2"
}
make_source() { # name: a source repo with main, a feature branch, a tag and a pull ref
  git init --quiet --bare --initial-branch=main "$work/src/$1.git"
  git init --quiet --initial-branch=main "$work/wt-$1"
  commit "$work/wt-$1" one
  git -C "$work/wt-$1" branch feature
  git -C "$work/wt-$1" tag v1
  git -C "$work/wt-$1" push --quiet "$work/src/$1.git" main feature v1
  git -C "$work/src/$1.git" update-ref refs/pull/1/head "$(git -C "$work/wt-$1" rev-parse HEAD)"
}
make_mirror() { # name: an empty mirror project
  git init --quiet --bare --initial-branch=main "$work/dst/$1.git"
}
refs_of() { git -C "$1" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags | sort; }
pushes_to_mirror() { grep -c 'git-receive-pack' "$work/dst.log" 2>/dev/null || true; }

sync_env() {
  env SRC_BASE="$src_base" DST_BASE="$dst_base" SRC_TOKEN="$src_token" DST_TOKEN="$dst_token" "$@"
}

# a checkout that disables credential prompts, as a GitLab runner makes, must not stop askpass
make_source runner
make_mirror runner
mkdir "$work/checkout" && git -C "$work/checkout" init --quiet && git -C "$work/checkout" config credential.interactive never
out="$(cd "$work/checkout" && sync_env "$dir/sync-repo.sh" runner "$work/cache-runner" 2>&1)"
is "a sync run inside a checkout with credential.interactive=never still gets its tokens" "$?" "$out"

# ---- sync-repo: the first run ------------------------------------------------
make_source alpha
make_mirror alpha
out="$(sync_env "$dir/sync-repo.sh" alpha "$work/cache-alpha" 2>&1)"
code=$?
is "the first sync succeeds" "$code" "exit $code: $out"
[ "$(tail -n 1 <<<"$out")" = synced ]
is "the first sync reports synced" "$?" "$out"
[ "$(refs_of "$work/src/alpha.git")" = "$(refs_of "$work/dst/alpha.git")" ] && [ -n "$(refs_of "$work/dst/alpha.git")" ]
is "branches and tags match the source" "$?" "$(refs_of "$work/dst/alpha.git")"
[ -z "$(git -C "$work/dst/alpha.git" for-each-ref refs/pull)" ] && git -C "$work/src/alpha.git" show-ref --quiet refs/pull/1/head
is "refs/pull/* is never copied" "$?" "$(git -C "$work/dst/alpha.git" for-each-ref refs/pull)"

# ---- tokens ------------------------------------------------------------------
grep -q ' 401$' "$work/src.log" && grep -q ' 401$' "$work/dst.log" && grep -q ' 200$' "$work/dst.log"
is "git asks askpass for the token on both servers" "$?" "$(cat "$work/src.log" "$work/dst.log")"
! grep -rqF -e "$src_token" -e "$dst_token" "$work/cache-alpha"
is "no token is in the cache repository" "$?" "found"
! grep -qF -e "$src_token" -e "$dst_token" <<<"$out"
is "no token is in the normal output" "$?" "found"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
trace_env=(GIT_TRACE=1 GIT_CURL_VERBOSE=1 GIT_TRACE_CURL=1 GIT_TRACE_PACKET=1)
traced="$(sync_env "${trace_env[@]}" "$dir/sync-repo.sh" alpha "$work/cache-trace" 2>&1)"
! grep -qF -e "$src_token" -e "$dst_token" -e "$(b64 "x-access-token:$src_token")" -e "$(b64 "oauth2:$dst_token")" <<<"$traced"
is "no token is in a fully verbose run" "$?" "found in trace"
unredacted="$(sync_env "${trace_env[@]}" GIT_TRACE_REDACT=0 "$dir/sync-repo.sh" alpha "$work/cache-trace2" 2>&1)"
grep -qF -e "$(b64 "x-access-token:$src_token")" <<<"$unredacted"
is "the same run with redaction off does show the token (so the test above can fail)" "$?" "token not visible"

stubs="$work/stubs"
mkdir -p "$stubs"
real_git="$(command -v git)"
cat >"$stubs/git" <<STUB
#!/usr/bin/env bash
echo "GIT: \$*" >>"\$GIT_LOG"
case "\$*" in
  *" fetch "*) [ -z "\${BEFORE_FETCH:-}" ] || eval "\$BEFORE_FETCH" ;;
esac
case "\$*" in
  *"/\${FAIL_REPO:-none}.git"*) echo "fatal: unable to access with \$DST_TOKEN" >&2; exit 128 ;;
  *"/\${SLOW_REPO:-none}.git"*) sleep 30 ;;
esac
exec "$real_git" "\$@"
STUB
chmod +x "$stubs/git"
: >"$work/git.log"
PATH="$stubs:$PATH" GIT_LOG="$work/git.log" sync_env "$dir/sync-repo.sh" alpha "$work/cache-alpha2" >/dev/null 2>&1
grep -q '^GIT: ' "$work/git.log" && ! grep -qF -e "$src_token" -e "$dst_token" "$work/git.log"
is "no token is on a git command line" "$?" "$(cat "$work/git.log")"
! grep -qE '^GIT: .*--mirror' "$work/git.log"
is "git never runs with --mirror" "$?" "$(cat "$work/git.log")"
grep -q 'credential.helper=' "$work/git.log"
is "git stores no credential in a helper" "$?" "no -c credential.helper="

ask() { env SYNC_SRC_HOST=h1:1 SYNC_DST_HOST=h2:2 SRC_TOKEN=SRCVAL DST_TOKEN=DSTVAL "$dir/askpass.sh" "$1"; }
[ "$(ask "Password for 'https://oauth2@h2:2': ")" = DSTVAL ]
is "askpass answers the mirror prompt with the mirror token" "$?" "wrong"
[ "$(ask "Password for 'https://x-access-token@h1:1': ")" = SRCVAL ]
is "askpass answers the source prompt with the source token" "$?" "wrong"
out="$(ask "Password for 'https://u@evil.example': ")"
code=$?
[ "$code" -ne 0 ] && [ -z "$out" ]
is "askpass gives no token to an unknown host" "$?" "exit $code, out: $out"
out="$(ask "Username for 'https://h2:2': ")"
code=$?
[ "$code" -ne 0 ] && [ -z "$out" ]
is "askpass answers no user name prompt" "$?" "exit $code, out: $out"
out="$(ask "Password for 'https://u@h2:2.evil.example': ")"
[ -z "$out" ]
is "askpass matches the whole host, not a prefix" "$?" "out: $out"
err="$(env SYNC_SRC_HOST=h1:1 SYNC_DST_HOST=h2:2 SRC_TOKEN=SRCVAL DST_TOKEN=DSTVAL "$dir/askpass.sh" "Password for 'https://u@evil.example': " 2>&1 >/dev/null)"
grep -q 'no token for this prompt (mirror host h2:2, source host h1:1)' <<<"$err" && ! grep -qE 'SRCVAL|DSTVAL' <<<"$err"
is "askpass names the prompt and both hosts when it has no answer, and prints no token" "$?" "$err"
err="$(env SYNC_SRC_HOST=h1:1 SYNC_DST_HOST=h2:2 SRC_TOKEN=SRCVAL DST_TOKEN=DSTVAL "$dir/askpass.sh" "Password for 'https://oauth2@h2:2': " 2>&1 >/dev/null)"
grep -q 'a token of 6 characters' <<<"$err" && ! grep -qE 'SRCVAL|DSTVAL' <<<"$err"
is "askpass states the length of the token it gives, and prints no token" "$?" "$err"

# ---- idempotency ---------------------------------------------------------------
before="$(pushes_to_mirror)"
out="$(sync_env "$dir/sync-repo.sh" alpha "$work/cache-alpha3" 2>&1)"
[ "$(tail -n 1 <<<"$out")" = unchanged ] && [ "$(pushes_to_mirror)" = "$before" ]
is "a second run changes nothing and sends no push" "$?" "$out, contacts $before -> $(pushes_to_mirror)"
[ ! -e "$work/cache-alpha3" ]
is "a run with nothing to do fetches nothing" "$?" "cache created"

# ---- new commits, tags, deletions, rewrites --------------------------------------
wt="$work/wt-alpha"
commit "$wt" two
git -C "$wt" tag v2
git -C "$wt" push --quiet "$work/src/alpha.git" main v2
git -C "$wt" push --quiet "$work/src/alpha.git" HEAD:refs/heads/topic
sync_env "$dir/sync-repo.sh" alpha "$work/c1" >/dev/null 2>&1
[ "$(refs_of "$work/src/alpha.git")" = "$(refs_of "$work/dst/alpha.git")" ] && git -C "$work/dst/alpha.git" show-ref --quiet refs/tags/v2 && git -C "$work/dst/alpha.git" show-ref --quiet refs/heads/topic
is "a new commit, tag and branch carry over" "$?" "$(refs_of "$work/dst/alpha.git")"

git -C "$work/src/alpha.git" update-ref -d refs/heads/topic
git -C "$work/src/alpha.git" update-ref -d refs/tags/v2
sync_env "$dir/sync-repo.sh" alpha "$work/c2" >/dev/null 2>&1
! git -C "$work/dst/alpha.git" show-ref --quiet refs/heads/topic && ! git -C "$work/dst/alpha.git" show-ref --quiet refs/tags/v2 && git -C "$work/dst/alpha.git" show-ref --quiet refs/heads/main
is "a deleted branch and a deleted tag are pruned" "$?" "$(refs_of "$work/dst/alpha.git")"

git -C "$wt" reset --quiet --hard HEAD~1
commit "$wt" rewritten
git -C "$wt" push --quiet --force "$work/src/alpha.git" main
git -C "$wt" push --quiet --force "$work/src/alpha.git" main:refs/heads/feature
sync_env "$dir/sync-repo.sh" alpha "$work/c3" >/dev/null 2>&1
[ "$(refs_of "$work/src/alpha.git")" = "$(refs_of "$work/dst/alpha.git")" ]
is "a rewritten default branch and a rewritten branch are accepted" "$?" "$(refs_of "$work/dst/alpha.git")"

# a source with no refs must not empty the mirror
git init --quiet --bare --initial-branch=main "$work/src/hollow.git"
make_mirror hollow
git -C "$wt" push --quiet "$work/dst/hollow.git" main
out="$(sync_env "$dir/sync-repo.sh" hollow "$work/c4" 2>&1)"
code=$?
[ "$code" -ne 0 ] && git -C "$work/dst/hollow.git" show-ref --quiet refs/heads/main
is "a source without refs fails and leaves the mirror alone" "$?" "exit $code: $out"

# a fetch that returns no branch is refused
git init --quiet --bare --initial-branch=main "$work/src/tagsonly.git"
git -C "$wt" push --quiet "$work/src/tagsonly.git" v1
make_mirror tagsonly
out="$(sync_env "$dir/sync-repo.sh" tagsonly "$work/c8" 2>&1)"
code=$?
[ "$code" -ne 0 ] && grep -q 'no branch' <<<"$out" && [ -z "$(refs_of "$work/dst/tagsonly.git")" ]
is "a source with tags and no branch is refused and nothing is pushed" "$?" "exit $code: $out"

# a source that changes between the listing and the fetch is refused, then the next run succeeds
commit "$wt" race-base
git -C "$wt" push --quiet --force "$work/src/alpha.git" main
race_hook="$real_git -C $wt push --quiet $work/src/alpha.git HEAD:refs/heads/raced"
out="$(PATH="$stubs:$PATH" GIT_LOG="$work/git.log" REAL_GIT="$real_git" BEFORE_FETCH="$race_hook" sync_env "$dir/sync-repo.sh" alpha "$work/c9" 2>&1)"
code=$?
[ "$code" -ne 0 ] && grep -q 'changed during the fetch' <<<"$out" && ! git -C "$work/dst/alpha.git" show-ref --quiet refs/heads/raced && [ "$(git -C "$work/dst/alpha.git" rev-parse refs/heads/main)" != "$(git -C "$wt" rev-parse HEAD)" ]
is "a source that changed during the fetch is refused and the mirror is untouched" "$?" "exit $code: $out"
out="$(sync_env "$dir/sync-repo.sh" alpha "$work/c10" 2>&1)"
[ "$(refs_of "$work/src/alpha.git")" = "$(refs_of "$work/dst/alpha.git")" ]
is "the next run after a refused race catches up" "$?" "$out"

# a prune of many refs is refused unless it is allowed
make_source prunery
make_mirror prunery
sync_env "$dir/sync-repo.sh" prunery "$work/c11" >/dev/null 2>&1
for n in 1 2 3 4 5 6 7; do git -C "$work/wt-prunery" push --quiet "$work/dst/prunery.git" "HEAD:refs/heads/extra$n"; done
out="$(sync_env "$dir/sync-repo.sh" prunery "$work/c12" 2>&1)"
code=$?
[ "$code" -ne 0 ] && grep -q 'would delete 7 refs' <<<"$out" && git -C "$work/dst/prunery.git" show-ref --quiet refs/heads/extra1
is "a run that would delete more than 5 refs is refused" "$?" "exit $code: $out"
out="$(sync_env SYNC_MAX_PRUNE=7 "$dir/sync-repo.sh" prunery "$work/c13" 2>&1)"
code=$?
[ "$code" -eq 0 ] && ! git -C "$work/dst/prunery.git" show-ref --quiet refs/heads/extra1
is "the limit can be raised with SYNC_MAX_PRUNE" "$?" "exit $code: $out"
for n in 1 2 3 4 5 6 7; do git -C "$work/wt-prunery" push --quiet "$work/dst/prunery.git" "HEAD:refs/heads/extra$n"; done
out="$(sync_env SYNC_ALLOW_PRUNE=1 "$dir/sync-repo.sh" prunery "$work/c14" 2>&1)"
code=$?
[ "$code" -eq 0 ] && ! git -C "$work/dst/prunery.git" show-ref --quiet refs/heads/extra1
is "SYNC_ALLOW_PRUNE=1 lets a large prune through" "$?" "exit $code: $out"

# a prune of the mirror default branch is refused unless it is allowed
make_source defdel
make_mirror defdel
git -C "$work/dst/defdel.git" config receive.denyDeleteCurrent ignore
sync_env "$dir/sync-repo.sh" defdel "$work/c15" >/dev/null 2>&1
git -C "$work/src/defdel.git" update-ref -d refs/heads/main
out="$(sync_env "$dir/sync-repo.sh" defdel "$work/c16" 2>&1)"
code=$?
[ "$code" -ne 0 ] && grep -q 'default branch main' <<<"$out" && git -C "$work/dst/defdel.git" show-ref --quiet refs/heads/main
is "a run that would delete the default branch of the mirror is refused" "$?" "exit $code: $out"
out="$(sync_env SYNC_ALLOW_PRUNE=1 "$dir/sync-repo.sh" defdel "$work/c17" 2>&1)"
code=$?
[ "$code" -eq 0 ] && ! git -C "$work/dst/defdel.git" show-ref --quiet refs/heads/main
is "SYNC_ALLOW_PRUNE=1 lets the default branch go" "$?" "exit $code: $out"

# bad inputs
out="$(sync_env "$dir/sync-repo.sh" '../etc' "$work/c5" 2>&1)"
is "a repository name with a slash is refused" "$([ $? -ne 0 ]; echo $?)" "$out"
out="$(env SRC_BASE="http://user:pw@127.0.0.1:1" DST_BASE="$dst_base" SRC_TOKEN=a DST_TOKEN=b "$dir/sync-repo.sh" alpha "$work/c6" 2>&1)"
is "a base URL that holds a user or token is refused" "$([ $? -ne 0 ]; echo $?)" "$out"
out="$(env SRC_BASE="$src_base" DST_BASE="$src_base" SRC_TOKEN=a DST_TOKEN=b "$dir/sync-repo.sh" alpha "$work/c7" 2>&1)"
is "the same host for source and mirror is refused" "$([ $? -ne 0 ]; echo $?)" "$out"

# a mirror project that does not exist yet is an empty mirror, so the push can create it
make_source delta
out="$(sync_env "$dir/sync-repo.sh" delta "$work/cache-delta" 2>&1)"
! grep -q 'cannot read the mirror project' <<<"$out"
is "a mirror project that does not exist is not a read failure" "$?" "$out"
rm -rf "$work/src/delta.git"

# ---- sync.sh: all repositories ---------------------------------------------------
make_source beta
make_source gamma
make_mirror beta
make_mirror gamma
printf '# a comment\nalpha\n\nbeta # trailing\nmissing\ngamma\n' >"$work/repos.txt"
out="$(sync_env REPOS_FILE="$work/repos.txt" "$dir/sync.sh" 2>&1)"
code=$?
[ "$code" -eq 1 ]
is "one failing repository gives a nonzero exit" "$?" "exit $code"
[ "$(refs_of "$work/src/beta.git")" = "$(refs_of "$work/dst/beta.git")" ] && [ "$(refs_of "$work/src/gamma.git")" = "$(refs_of "$work/dst/gamma.git")" ]
is "the repositories after the failing one still sync" "$?" "$out"
grep -q '^FAILED: missing' <<<"$out" && grep -q '4 repositories: 2 synced, 1 unchanged, 1 failed' <<<"$out" && grep -q '^failed: missing$' <<<"$out"
is "the summary counts the results and names the failed repository" "$?" "$out"
grep -q '^ok: alpha (unchanged)' <<<"$out" && grep -q '^ok: beta (synced)' <<<"$out"
is "the summary lists each repository with its result" "$?" "$out"
printf 'alpha\nbeta\ngamma\n' >"$work/repos.txt"
out="$(sync_env REPOS_FILE="$work/repos.txt" "$dir/sync.sh" 2>&1)"
code=$?
[ "$code" -eq 0 ] && grep -q '3 repositories: 0 synced, 3 unchanged, 0 failed' <<<"$out"
is "when every repository is current the run exits 0" "$?" "exit $code: $out"

# a failing repository hides the token in its reason
printf 'alpha\nbeta\n' >"$work/repos.txt"
commit "$work/wt-beta" next
git -C "$work/wt-beta" push --quiet "$work/src/beta.git" main
out="$(PATH="$stubs:$PATH" GIT_LOG="$work/git.log" FAIL_REPO=beta sync_env REPOS_FILE="$work/repos.txt" "$dir/sync.sh" 2>&1)"
code=$?
! grep -qF "$dst_token" <<<"$out" && grep -q 'hidden' <<<"$out" && [ "$code" -eq 1 ]
is "a token inside a failure message is hidden" "$?" "exit $code: $out"

# a repository that hangs is stopped and the rest still run
commit "$work/wt-beta" again
git -C "$work/wt-beta" push --quiet "$work/src/beta.git" main
commit "$work/wt-gamma" gamma-two
git -C "$work/wt-gamma" push --quiet "$work/src/gamma.git" main
printf 'alpha\nbeta\ngamma\n' >"$work/repos.txt"
out="$(PATH="$stubs:$PATH" GIT_LOG="$work/git.log" SLOW_REPO=beta SYNC_TIMEOUT=2 sync_env REPOS_FILE="$work/repos.txt" "$dir/sync.sh" 2>&1)"
code=$?
grep -q 'timed out after 2 seconds' <<<"$out" && [ "$code" -eq 1 ] && [ "$(refs_of "$work/src/gamma.git")" = "$(refs_of "$work/dst/gamma.git")" ]
is "a hanging repository times out and the next one still syncs" "$?" "exit $code: $out"

# refusals
out="$(sync_env REPOS_FILE="$work/repos.txt" bash -x "$dir/sync.sh" 2>&1)"
is "sync.sh refuses to run under bash -x" "$([ $? -ne 0 ] && grep -q 'tracing is on' <<<"$out"; echo $?)" "$(head -c 300 <<<"$out")"
out="$(env SRC_BASE="$src_base" DST_BASE="$dst_base" SRC_TOKEN=same DST_TOKEN=same "$dir/sync.sh" 2>&1)"
is "sync.sh refuses one value for both tokens" "$([ $? -ne 0 ]; echo $?)" "$out"
printf 'alpha\nalpha\n' >"$work/dup.txt"
out="$(sync_env REPOS_FILE="$work/dup.txt" "$dir/sync.sh" 2>&1)"
is "sync.sh refuses a repository listed twice" "$([ $? -ne 0 ] && grep -q twice <<<"$out"; echo $?)" "$out"
printf '# nothing\n' >"$work/none.txt"
out="$(sync_env REPOS_FILE="$work/none.txt" "$dir/sync.sh" 2>&1)"
is "sync.sh refuses an empty list" "$([ $? -ne 0 ]; echo $?)" "$out"

# ---- loop.sh ---------------------------------------------------------------------
# A stand-in for sync.sh that logs each call and fails the first time.
loop_dir="$work/loop"
mkdir -p "$loop_dir"
cp "$dir/loop.sh" "$loop_dir/loop.sh"
printf '#!/usr/bin/env bash
echo run >>"%s/calls"
[ "$(wc -l <"%s/calls")" -gt 1 ]
' "$work" "$work" >"$loop_dir/sync.sh"
chmod +x "$loop_dir/loop.sh" "$loop_dir/sync.sh"
started="$(date +%s)"
env INTERVAL=1 HEARTBEAT="$work/heartbeat" "$loop_dir/loop.sh" >"$work/loop.out" 2>&1 &
loop_pid=$!
sleep 3.5
calls="$(wc -l <"$work/calls")"
# A busy runner can overshoot the sleep, so the bounds follow the time that really passed:
# one call at the start and one more for each whole second, give or take one.
elapsed=$(($(date +%s) - started))
[ "$calls" -ge "$elapsed" ] && [ "$calls" -le $((elapsed + 2)) ]
is "the loop runs sync.sh once every interval" "$?" "calls: $calls in about $elapsed seconds"
grep -q 'the run failed' "$work/loop.out"
is "a failed run does not stop the loop" "$?" "$(cat "$work/loop.out")"
[ -e "$work/heartbeat" ]
is "the loop touches the heartbeat file after a run" "$?" "no heartbeat"
kill -TERM "$loop_pid"
for _ in $(seq 1 20); do kill -0 "$loop_pid" 2>/dev/null || break; sleep 0.1; done
! kill -0 "$loop_pid" 2>/dev/null
is "the loop stops at once on SIGTERM" "$?" "still running"

# ---- what the chart renders ------------------------------------------------------
if command -v helm >/dev/null; then
  out="$(helm template m "$repo/apps/mirror-sync")"
  grep -q 'kind: Deployment' <<<"$out" && grep -q 'replicas: 1' <<<"$out" && grep -q 'type: Recreate' <<<"$out" && ! grep -q 'kind: CronJob' <<<"$out"
  is "the sync is one pod that never overlaps itself" "$?" "$out"
  grep -q 'defaultMode: 0555' <<<"$out" && grep -q 'bash", "/scripts/loop.sh' <<<"$out"
  is "the scripts are mounted executable and the pod runs the loop" "$?" "$out"
  grep -q 'name: gitlab-mirror' <<<"$out" && grep -q 'name: github-source' <<<"$out" && ! grep -qE 'glpat-|ghp_' <<<"$out"
  is "both tokens come from Secrets and none is in the chart" "$?" "$out"
  out="$(helm template m "$repo/apps/mirror-sync")"
  grep -q 'value: "650"' <<<"$out"
  is "the run deadline is the repository count times the repository timeout plus 10" "$?" "$(grep -n 'RUN_DEADLINE' -A1 <<<"$out")"
  out="$(helm template m "$repo/apps/mirror-sync" --set repos='{one}')"
  grep -q 'value: "300"' <<<"$out"
  is "a short list still gets the minimum run deadline" "$?" "$(grep -n 'RUN_DEADLINE' -A1 <<<"$out")"
  out="$(helm template m "$repo/apps/mirror-sync" --set repos='{one,two}' | sed -n '/repos.txt/,/sync.sh/p')"
  grep -q 'one' <<<"$out" && grep -q 'two' <<<"$out" && ! grep -q 'kube-compute' <<<"$out"
  is "the repository list is a value" "$?" "$out"
  out="$(helm template b "$repo/bootstrap" | grep -A25 'name: mirror-sync')"
  grep -q 'path: apps/mirror-sync' <<<"$out" && grep -q 'namespace: gitlab' <<<"$out"
  is "the bootstrap installs the sync in the gitlab namespace" "$?" "$out"
else
  report "chart render tests" "helm is missing (it is in the kube-devenv image)"
fi

[ "$failures" -eq 0 ] && echo "all mirror sync tests passed" || { echo "$failures mirror sync test(s) failed"; exit 1; }
