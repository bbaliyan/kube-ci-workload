#!/usr/bin/env bash
# Integration test on a real cluster. It installs GitLab, the first-objects Job and the runner
# from this repo into two scratch namespaces, then checks what they made, pushes a project and
# waits for a pipeline to pass on the runner. It deletes the namespaces at the end.
#
#   KUBECONFIG=~/.kube/ci.yaml tests/integration.sh
#
# Not part of make test-commit. It needs kubectl, helm and jq, a cluster with the local-path storage
# class and the Traefik CRDs, and a node that can take GitLab (tests/integration-gitlab.yaml picks
# the idle privileged node). The first start of GitLab takes 3 to 10 minutes.
#
# Inputs (environment):
#   IT_NAMESPACE         optional. Default gitlab-it.
#   IT_RUNNER_NAMESPACE  optional. Default gitlab-runner-it.
#   KEEP                 optional. Set to 1 to keep the namespaces.
# Both names must end in -it, so the test can never touch a real namespace.
# shellcheck disable=SC2319 # "$?" right after a test command is the point of the is() helper
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
ns="${IT_NAMESPACE:-gitlab-it}"
rns="${IT_RUNNER_NAMESPACE:-gitlab-runner-it}"
work="$(mktemp -d)"
failures=0

for tool in kubectl helm jq; do
  command -v "$tool" >/dev/null || { echo "tests/integration.sh needs $tool" >&2; exit 2; }
done
[[ "$ns" == *-it && "$rns" == *-it ]] || { echo "IT_NAMESPACE and IT_RUNNER_NAMESPACE must end in -it" >&2; exit 2; }
kubectl get nodes >/dev/null 2>&1 || { echo "cannot reach a cluster. Set KUBECONFIG." >&2; exit 2; }
for n in "$ns" "$rns"; do
  ! kubectl get namespace "$n" >/dev/null 2>&1 || { echo "namespace $n exists. Delete it first." >&2; exit 2; }
done

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then
    echo "kept namespaces $ns and $rns"
  else
    kubectl delete namespace "$ns" "$rns" --wait=false >/dev/null 2>&1
  fi
  rm -rf "$work"
}
trap cleanup EXIT

report() { if [ "$2" = ok ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; failures=$((failures + 1)); fi; }
is() { if [ "$2" -eq 0 ]; then report "$1" ok; else report "$1" "${3:-failed}"; fi; }
finish() { [ "$failures" -eq 0 ] && echo "all integration tests passed" || { echo "$failures integration test(s) failed"; exit 1; }; }
die() { echo "FAIL: $*" >&2; failures=$((failures + 1)); finish; }

in_gitlab() { kubectl -n "$ns" exec gitlab-0 -- "$@"; }
secret() { kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | base64 -d; }
api() { # token, path
  in_gitlab curl -s -H "PRIVATE-TOKEN: $1" "http://localhost/api/v4$2"
}

kubectl create namespace "$ns" >/dev/null && kubectl create namespace "$rns" >/dev/null || die "cannot create the namespaces"

echo "installing GitLab (the first start takes several minutes)"
helm template gitlab "$repo/apps/gitlab" -n "$ns" -f "$repo/tests/integration-gitlab.yaml" | kubectl apply -n "$ns" -f - >/dev/null || die "cannot apply the GitLab app"
kubectl -n "$ns" rollout status statefulset/gitlab --timeout=30m >/dev/null 2>&1
is "the GitLab pod becomes ready" "$?" "$(kubectl -n "$ns" describe pod gitlab-0 | tail -15)"
[ "$failures" -eq 0 ] || finish

helm template first-objects "$repo/apps/first-objects" -n "$ns" \
  --set "gitlabNamespace=$ns" --set "runnerNamespace=$rns" --set "gitlabApi=http://gitlab.$ns.svc.cluster.local" |
  kubectl apply -f - >/dev/null || die "cannot apply the first-objects app"
kubectl -n "$ns" wait --for=condition=complete job/first-objects --timeout=20m >/dev/null 2>&1
is "the first-objects Job completes" "$?" "$(kubectl -n "$ns" logs job/first-objects --tail=15 2>&1)"
[ "$failures" -eq 0 ] || finish

root_password="$(secret "$ns" gitlab-root password)"
mirror_token="$(secret "$ns" gitlab-mirror token)"
runner_token="$(secret "$rns" gitlab-runner runner-token)"
[ -n "$root_password" ] && [ -n "$mirror_token" ] && [ -n "$runner_token" ]
is "the three Secrets hold values" "$?" "a Secret is empty"

in_gitlab gitlab-rails runner "puts User.find_by_username('root').valid_password?('$root_password')" 2>/dev/null | tail -n 1 | grep -qx true
is "the root password in the Secret is valid" "$?" "password"

[ "$(in_gitlab curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost/api/v4/runners/verify --data-urlencode "token=$runner_token")" = 200 ]
is "GitLab accepts the runner token" "$?" "runner verify"

api "$mirror_token" /groups/mirror | jq -e '.visibility == "private"' >/dev/null
is "the mirror token sees the private mirror group" "$?" "group"

in_gitlab gitlab-rails runner "puts User.find_by_username('root').personal_access_tokens.active.where(name: 'first-objects').count" 2>/dev/null | tail -n 1 | grep -qx 0
is "the admin token of the Job is revoked" "$?" "token"

echo "installing the runner"
sed "s#gitlab.gitlab.svc.cluster.local#gitlab.$ns.svc.cluster.local#g" "$repo/apps/gitlab-runner/values.yaml" >"$work/runner-values.yaml"
helm dependency build "$repo/apps/gitlab-runner" >/dev/null 2>&1
helm template runner "$repo/apps/gitlab-runner" -n "$rns" -f "$work/runner-values.yaml" | kubectl apply -n "$rns" -f - >/dev/null
kubectl -n "$rns" wait --for=condition=Available deployment --all --timeout=5m >/dev/null 2>&1
is "the runner starts" "$?" "$(kubectl -n "$rns" get pods 2>&1)"

# Push a project that has a pipeline file. The first push creates the project (push-to-create).
in_gitlab sh -c "set -e; d=\$(mktemp -d); cd \"\$d\"; git init -q -b main; printf 'test:\n  script:\n    - echo hello\n' > .gitlab-ci.yml; git add .; git -c user.name=test -c user.email=test@example.invalid commit -q -m ci; git push -q http://oauth2:$mirror_token@localhost/mirror/pipelinetest.git main" >/dev/null 2>&1
is "the mirror token creates a project with its first push" "$?" "push"

status=""
for _ in $(seq 1 60); do
  status="$(api "$mirror_token" "/projects/mirror%2Fpipelinetest/pipelines" | jq -r '.[0].status // empty')"
  case "$status" in success | failed | canceled) break ;; esac
  sleep 10
done
[ "$status" = success ]
is "a pipeline of the pushed project passes on the runner" "$?" "pipeline status: ${status:-none}; $(kubectl -n "$rns" get pods 2>&1 | tail -5)"

finish
