#!/usr/bin/env bash
# Tests for apps/first-objects/files/first-objects.sh. kubectl, curl and the
# GitLab container are stand-ins that log what they are asked.
# Run: tests/first-objects.sh
# shellcheck disable=SC2319 # "$?" right after a test command is the point of the is() helper
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo/apps/first-objects/files/first-objects.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

command -v jq >/dev/null || { echo "tests/first-objects.sh needs jq (it is in the kube-devenv image)" >&2; exit 2; }

report() { # name, ok or the reason
  if [ "$2" = ok ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; failures=$((failures + 1)); fi
}
is() { # name, condition result (0 = pass), detail
  if [ "$2" -eq 0 ]; then report "$1" ok; else report "$1" "${3:-failed}"; fi
}

stubs="$work/stubs"
mkdir -p "$stubs"

# kubectl: "get secret" succeeds for names listed in $STATE/secrets. "apply" records the secret
# name and its keys. Everything else is logged.
cat >"$stubs/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >>"$STATE/kubectl.log"
case "$*" in
  *"get secret "*)
    name="${*: -1}"
    grep -qx "$name" "$STATE/secrets" 2>/dev/null
    exit $?
    ;;
  *"create secret generic "*)
    # Record "name key key ..." in a pending file that the next apply moves into place.
    name="$(sed -E 's/.*create secret generic ([^ ]+).*/\1/' <<<"$*")"
    keys="$(grep -oE -- '--from-literal=[^=]+=' <<<"$*" | sed -E 's/--from-literal=//; s/=$//' | tr '\n' ' ')"
    echo "$name $keys" >"$STATE/pending"
    echo "apiVersion: v1"
    ;;
  *"apply -f -"*)
    cat >/dev/null
    cat "$STATE/pending" >>"$STATE/applied"
    awk '{print $1}' "$STATE/pending" >>"$STATE/secrets"
    ;;
esac
exit 0
STUB

# gitlab-rails runner: answers with a password (only when the code sets one) and a token.
cat >"$stubs/gitlab-exec" <<'STUB'
#!/usr/bin/env bash
echo "gitlab-exec $1 $2" >>"$STATE/rails.log"
printf '%s\n' "$5" >>"$STATE/rails.code"
echo "Booting the rails runner"
if grep -q 'if true' <<<"$5"; then
  echo '{"password":"ROOTPASSWORD123","token":"ADMINTOKEN456"}'
else
  echo '{"password":null,"token":"ADMINTOKEN456"}'
fi
STUB

# curl: the token comes in on stdin. Answers by method and path.
cat >"$stubs/curl" <<'STUB'
#!/usr/bin/env bash
cat >>"$STATE/curl.stdin"
echo "curl $*" >>"$STATE/curl.log"
case "$*" in
  *"--request GET"*"/groups/mirror"*)
    if [ -n "${GROUP_EXISTS:-}" ]; then echo '{"id":7}'; else echo '{"message":"404 Group Not Found"}' >&2; exit 22; fi ;;
  *"--request POST"*"/groups/7/access_tokens"*) echo '{"token":"MIRRORTOKEN789"}' ;;
  *"--request POST"*"/groups"*) echo '{"id":7}' ;;
  *"--request POST"*"/user/runners"*) echo '{"token":"glrt-RUNNERTOKEN012"}' ;;
  *"--request DELETE"*) echo '{}' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$stubs"/*

run() { # case name, extra env assignments...
  local name="$1"
  shift
  case_dir="$work/$name"
  mkdir -p "$case_dir"
  : >"$case_dir/secrets"
  [ -z "${SECRETS:-}" ] || printf '%s\n' $SECRETS >"$case_dir/secrets"
  out="$(env PATH="$stubs:$PATH" STATE="$case_dir" \
    GITLAB_NAMESPACE=gitlab GITLAB_POD=gitlab-0 RUNNER_NAMESPACE=gitlab-runner GITLAB_API=http://gitlab.example.invalid \
    GITLAB_EXEC="$stubs/gitlab-exec x y" "$@" bash "$script" 2>&1)"
  code=$?
}
no_secret_in() { # text: none of the token values is in it
  ! grep -qE 'ROOTPASSWORD123|ADMINTOKEN456|MIRRORTOKEN789|RUNNERTOKEN012' <<<"$1"
}

# ---- a new GitLab ------------------------------------------------------------------
SECRETS="" run fresh
[ "$code" -eq 0 ] && grep -q 'first-objects: done' <<<"$out"
is "a new GitLab gets its first objects" "$?" "exit $code: $out"
[ "$(awk '{print $1}' "$case_dir/applied" | sort | tr '\n' ' ')" = "gitlab-mirror gitlab-root gitlab-runner " ]
is "the three Secrets are saved" "$?" "$(cat "$case_dir/applied")"
grep -q '^gitlab-root username password' "$case_dir/applied" && grep -q '^gitlab-mirror token' "$case_dir/applied" && grep -q '^gitlab-runner runner-token runner-registration-token' "$case_dir/applied"
is "each Secret has the keys the other apps read" "$?" "$(cat "$case_dir/applied")"
no_secret_in "$out"
is "no token or password is printed" "$?" "$out"
! grep -qE 'ROOTPASSWORD123|ADMINTOKEN456|MIRRORTOKEN789|RUNNERTOKEN012' "$case_dir/curl.log"
is "no token is on a curl command line" "$?" "$(cat "$case_dir/curl.log")"
[ "$(grep -c 'PRIVATE-TOKEN: ADMINTOKEN456' "$case_dir/curl.stdin")" -ge 3 ]
is "the admin token reaches curl through stdin" "$?" "$(cat "$case_dir/curl.stdin")"
grep -q -- '--request DELETE .*personal_access_tokens/self' "$case_dir/curl.log"
is "the admin token is revoked at the end" "$?" "$(cat "$case_dir/curl.log")"
grep -q 'wait --for=condition=Ready pod/gitlab-0' "$case_dir/kubectl.log"
is "it waits for the GitLab pod" "$?" "$(cat "$case_dir/kubectl.log")"
grep -q 'visibility=private' "$case_dir/curl.log" && grep -q 'access_level=40' "$case_dir/curl.log" && grep -q 'run_untagged=true' "$case_dir/curl.log"
is "the group is private, the mirror token is a maintainer and the runner takes untagged jobs" "$?" "$(cat "$case_dir/curl.log")"
grep -q 'if true' "$case_dir/rails.code"
is "a new GitLab gets a new root password" "$?" "$(cat "$case_dir/rails.code")"

# ---- run again -------------------------------------------------------------------------
SECRETS="gitlab-root gitlab-mirror gitlab-runner" run again GROUP_EXISTS=1
[ "$code" -eq 0 ] && [ ! -e "$case_dir/applied" ] && ! grep -q -- '--request POST' "$case_dir/curl.log" && grep -q -- '--request PUT .*/application/settings' "$case_dir/curl.log"
is "with all three Secrets present it makes no object and still applies the settings" "$?" "exit $code: $out"

# ---- partial state -------------------------------------------------------------------------
SECRETS="gitlab-root" run partial
[ "$code" -eq 0 ] && grep -q 'if false' "$case_dir/rails.code" && ! grep -q '^gitlab-root' "$case_dir/applied"
is "with the root Secret present it keeps the root password" "$?" "exit $code: $out"
grep -q '^gitlab-mirror' "$case_dir/applied" && grep -q '^gitlab-runner' "$case_dir/applied"
is "with the root Secret present it still saves the other two" "$?" "$(cat "$case_dir/applied")"

grep -q -- '--request PUT .*/application/settings .*auto_devops_enabled=false' "$case_dir/curl.log" 2>/dev/null
is "Auto DevOps is turned off for the instance" "$?" "$(head -8 "$case_dir/curl.log" 2>/dev/null)"
grep -q -- '--request PUT .*/groups/7 .*default_branch_protection=0' "$case_dir/curl.log" 2>/dev/null
is "the mirror group allows a force push on its default branch" "$?" "$(cat "$case_dir/curl.log" 2>/dev/null | head -5)"

SECRETS="" run group-exists GROUP_EXISTS=1
[ "$code" -eq 0 ] && ! grep -q -- '--request POST .*/groups --' "$case_dir/curl.log" && ! grep -q 'created group' <<<"$out"
is "an existing group is reused" "$?" "exit $code: $out"

# ---- failures -----------------------------------------------------------------------------------
SECRETS="" run bad-api GITLAB_API=http://user:pw@gitlab.example.invalid
[ "$code" -ne 0 ] && [ ! -e "$case_dir/rails.log" ]
is "an address with a user part is refused" "$?" "exit $code: $out"
SECRETS="" run bad-group MIRROR_GROUP='Bad Group'
[ "$code" -ne 0 ] && [ ! -e "$case_dir/rails.log" ]
is "a group name with a space is refused" "$?" "exit $code: $out"
cat >"$stubs/gitlab-exec-broken" <<'STUB'
#!/usr/bin/env bash
echo "no json here"
STUB
chmod +x "$stubs/gitlab-exec-broken"
SECRETS="" run broken-rails GITLAB_EXEC="$stubs/gitlab-exec-broken x y"
[ "$code" -ne 0 ] && [ ! -s "$case_dir/applied" ]
is "if gitlab-rails gives no token it fails and saves nothing" "$?" "exit $code: $out"
out="$(env PATH="$stubs:$PATH" STATE="$work/trace" bash -x "$script" 2>&1)"
! grep -qE 'ROOTPASSWORD123|ADMINTOKEN456' <<<"$out"
is "tracing the script shows no token" "$?" "$out"

[ "$failures" -eq 0 ] && echo "all first-objects tests passed" || { echo "$failures first-objects test(s) failed"; exit 1; }
