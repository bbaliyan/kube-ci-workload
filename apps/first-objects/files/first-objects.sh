#!/usr/bin/env bash
# Create the first GitLab objects, once, and the Secrets that other apps read:
#   gitlab-root    (namespace $GITLAB_NAMESPACE)  keys username, password
#   gitlab-mirror  (namespace $GITLAB_NAMESPACE)  key token: a group token that pushes to the mirror group
#   gitlab-runner  (namespace $RUNNER_NAMESPACE)  keys runner-token, runner-registration-token
#
# A new GitLab has no group, no runner and no known root password, and the GitLab API
# cannot create the first token. The one thing that can is GitLab's own `gitlab-rails runner`,
# so this script uses it once, for a short-lived admin token, and the API for the rest.
#
# Inputs (environment):
#   GITLAB_NAMESPACE  required. GITLAB_POD required. RUNNER_NAMESPACE required.
#   GITLAB_API        required. The address of the GitLab API, for example http://gitlab.gitlab.svc.
#   MIRROR_GROUP      optional. Default mirror.
#   GITLAB_EXEC       optional. The command that runs a program inside the GitLab container.
#                     Default: kubectl -n $GITLAB_NAMESPACE exec $GITLAB_POD --
#   GITLAB_READY_TIMEOUT optional. Default 30m.
#
# Safe to run again: a Secret that exists is left alone. No token is printed or put in an argument
# of a program outside this container.
set -euo pipefail

fail() { echo "first-objects: $*" >&2; exit 1; }

: "${GITLAB_NAMESPACE:?set GITLAB_NAMESPACE}" "${GITLAB_POD:?set GITLAB_POD}" "${RUNNER_NAMESPACE:?set RUNNER_NAMESPACE}" "${GITLAB_API:?set GITLAB_API}"
group="${MIRROR_GROUP:-mirror}"
[[ "$group" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "bad MIRROR_GROUP: $group"
[[ "$GITLAB_API" =~ ^https?://[^/@]+$ ]] || fail "GITLAB_API must be http(s)://host with no path, user or token"
case "$-" in *x*) fail "shell tracing is on. Stopping before this script prints a token." ;; esac

if [ -n "${GITLAB_EXEC:-}" ]; then
  read -r -a exec_in_gitlab <<<"$GITLAB_EXEC"
else
  exec_in_gitlab=(kubectl -n "$GITLAB_NAMESPACE" exec "$GITLAB_POD" --)
fi

have_secret() { kubectl -n "$1" get secret "$2" >/dev/null 2>&1; }

if have_secret "$GITLAB_NAMESPACE" gitlab-root && have_secret "$GITLAB_NAMESPACE" gitlab-mirror && have_secret "$RUNNER_NAMESPACE" gitlab-runner; then
  echo "first-objects: the Secrets exist. Nothing to do."
  exit 0
fi

kubectl -n "$GITLAB_NAMESPACE" wait --for=condition=Ready "pod/$GITLAB_POD" --timeout="${GITLAB_READY_TIMEOUT:-30m}"

# One short-lived admin token. The root password changes only if no Secret holds it yet.
set_password=true
! have_secret "$GITLAB_NAMESPACE" gitlab-root || set_password=false
ruby="
require 'json'
user = User.find_by_username('root')
password = nil
if $set_password
  password = SecureRandom.alphanumeric(32)
  user.password = password
  user.password_confirmation = password
  user.password_automatically_set = false
  user.save!
end
token = user.personal_access_tokens.create!(name: 'first-objects', scopes: [:api, :create_runner], expires_at: 1.day.from_now)
puts({ password: password, token: token.token }.to_json)
"
bootstrap="$("${exec_in_gitlab[@]}" gitlab-rails runner "$ruby" | tail -n 1)" || fail "gitlab-rails runner failed"
admin_token="$(jq -er .token <<<"$bootstrap")" || fail "gitlab-rails runner gave no token"
root_password="$(jq -r '.password // empty' <<<"$bootstrap")"
unset bootstrap

api() { # method, path, curl arguments...: the token reaches curl through stdin
  local method="$1" path="$2"
  shift 2
  printf 'header = "PRIVATE-TOKEN: %s"\n' "$admin_token" |
    curl --silent --show-error --fail-with-body --max-time 60 --config - --request "$method" "$GITLAB_API/api/v4$path" "$@"
}
trap 'api DELETE /personal_access_tokens/self >/dev/null 2>&1 || true' EXIT

put_secret() { # namespace, name, key=value...: create or update a Secret without printing it
  local ns="$1" name="$2"
  shift 2
  local args=() pair
  for pair in "$@"; do args+=("--from-literal=$pair"); done
  kubectl -n "$ns" create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

if [ -n "$root_password" ]; then
  put_secret "$GITLAB_NAMESPACE" gitlab-root "username=root" "password=$root_password"
  echo "first-objects: saved Secret gitlab-root"
fi
unset root_password

group_id="$(api GET "/groups/$group" 2>/dev/null | jq -r .id || true)"
if [ -z "$group_id" ] || [ "$group_id" = null ]; then
  group_id="$(api POST /groups --data-urlencode "name=$group" --data-urlencode "path=$group" --data-urlencode visibility=private | jq -er .id)" || fail "cannot create the group $group"
  echo "first-objects: created group $group"
fi

# A mirror follows GitHub, which may rewrite or delete a default branch. A protected default branch
# would refuse that push on every run, so the mirror group turns the protection off.
api PUT "/groups/$group_id" --data-urlencode default_branch_protection=0 >/dev/null || fail "cannot update the group $group"

if ! have_secret "$GITLAB_NAMESPACE" gitlab-mirror; then
  expires="$(date -u -d '+364 days' +%Y-%m-%d)"
  mirror_token="$(api POST "/groups/$group_id/access_tokens" \
    --data-urlencode name=mirror-sync --data-urlencode "expires_at=$expires" --data-urlencode access_level=40 \
    --data-urlencode "scopes[]=api" --data-urlencode "scopes[]=write_repository" | jq -er .token)" || fail "cannot create the mirror token"
  put_secret "$GITLAB_NAMESPACE" gitlab-mirror "token=$mirror_token"
  unset mirror_token
  echo "first-objects: saved Secret gitlab-mirror"
fi

if ! have_secret "$RUNNER_NAMESPACE" gitlab-runner; then
  runner_token="$(api POST /user/runners \
    --data-urlencode runner_type=instance_type --data-urlencode description=general \
    --data-urlencode tag_list=commit --data-urlencode run_untagged=true --data-urlencode maximum_timeout=3600 | jq -er .token)" || fail "cannot create the runner"
  put_secret "$RUNNER_NAMESPACE" gitlab-runner "runner-token=$runner_token" "runner-registration-token="
  unset runner_token
  echo "first-objects: saved Secret gitlab-runner"
fi

echo "first-objects: done"
