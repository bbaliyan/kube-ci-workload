#!/usr/bin/env bash
# Tests for what the charts render: the GitLab address settings, the tailnet Ingress and the LAN route.
# Run: tests/render.sh
# shellcheck disable=SC2319 # "$?" right after a test command is the point of the is() helper
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

command -v helm >/dev/null || { echo "tests/render.sh needs helm (it is in the kube-devenv image)" >&2; exit 2; }

report() { # name, ok or the reason
  if [ "$2" = ok ]; then echo "ok: $1"; else echo "FAIL: $1 ($2)"; failures=$((failures + 1)); fi
}
is() { # name, condition result (0 = pass), detail
  if [ "$2" -eq 0 ]; then report "$1" ok; else report "$1" "${3:-failed}"; fi
}

gitlab() { helm template gitlab "$repo/apps/gitlab" "$@"; }

out="$(gitlab --set externalUrl=https://git-ci.example.ts.net)"
grep -q "external_url 'https://git-ci.example.ts.net'" <<<"$out" && grep -q "nginx\['listen_https'\] = false" <<<"$out" \
  && grep -q "letsencrypt\['enable'\] = false" <<<"$out" && grep -q '"X-Forwarded-Proto" => "https"' <<<"$out"
is "an https address makes GitLab listen on plain HTTP behind the proxy, with no Let's Encrypt" "$?" "$out"

out="$(gitlab --set externalUrl=http://git.example.test)"
! grep -q 'listen_https' <<<"$out" && ! grep -q 'letsencrypt' <<<"$out"
is "an http address adds no proxy settings" "$?" "$out"

out="$(gitlab)"
! grep -q 'kind: Ingress' <<<"$out" && ! grep -q 'kind: IngressRoute' <<<"$out"
is "by default GitLab has no Ingress and no LAN route" "$?" "$out"

out="$(gitlab --set tailnet.enabled=true --set externalUrl=https://git-ci.example.ts.net)"
grep -q 'tailscale.com/http-endpoint: enabled' <<<"$out" && grep -q 'ingressClassName: tailscale' <<<"$out" && grep -q 'tailscale.com/proxy-group: ci-proxy' <<<"$out" \
  && ! grep -q 'tailscale.com/hostname' <<<"$out" && grep -A2 'tls:' <<<"$out" | grep -q -- '- git-ci'
is "the tailnet Ingress takes its host name from the first label of externalUrl, through a ProxyGroup, and asks for a certificate" "$?" "$out"
! grep -q 'kind: ProxyGroup' <<<"$out"
is "the GitLab chart makes no ProxyGroup: the operator app owns it" "$?"

tailscale="$(mktemp -d)"
trap 'rm -rf "$tailscale"' EXIT
cp -r "$repo/apps/tailscale-operator/Chart.yaml" "$repo/apps/tailscale-operator/values.yaml" "$repo/apps/tailscale-operator/templates" "$tailscale/"
helm repo add tailscale https://pkgs.tailscale.com/helmcharts --force-update >/dev/null && helm dependency update "$tailscale" >/dev/null
out="$(helm template ts "$tailscale" --namespace tailscale --show-only templates/proxygroup.yaml)"
grep -q 'kind: ProxyGroup' <<<"$out" && grep -q 'type: ingress' <<<"$out" && grep -q 'name: ci-proxy' <<<"$out" && grep -A1 'tags:' <<<"$out" | grep -q -- '- tag:ci'
is "the operator app makes a ProxyGroup of type ingress that carries the tag" "$?" "$out"
grep -q 'replicas: 2' <<<"$out" && grep -q 'hostnamePrefix: ci-proxy' <<<"$out"
is "the ProxyGroup runs two pods named ci-proxy-0 and ci-proxy-1" "$?" "$out"
! helm template ts "$tailscale" --set proxyGroup.enabled=false | grep -qx 'kind: ProxyGroup'
is "the ProxyGroup can be turned off" "$?"
grep -q 'sync-wave: "1"' <<<"$out"
is "the ProxyGroup syncs after the operator CRDs" "$?" "$out"
out="$(helm template ts "$tailscale" --set tailscale-operator.proxyConfig.defaultTags='tag:ci\,tag:two' --show-only templates/proxygroup.yaml)"
grep -qx '    - tag:ci' <<<"$out" && grep -qx '    - tag:two' <<<"$out"
is "a list of tags becomes one tag each" "$?" "$out"

out="$(gitlab --set lanHost=git.example.test)"
grep -q 'Host(`git.example.test`)' <<<"$out" && grep -q 'kind: IngressRoute' <<<"$out"
is "a LAN host name makes a Traefik route" "$?" "$out"

out="$(helm template b "$repo/bootstrap" --set tailscale.helmValues.proxyGroup.name=other --set gitlab.helmValues.tailnet.proxyGroup=other2 | grep -E 'proxyGroup|name: (ci-proxy|other)')"
! grep -qE 'other' <<<"$out"
is "an override cannot split the ProxyGroup name between the operator and GitLab" "$?" "$out"
! gitlab --set tailnet.enabled=true --set externalUrl=https://git_ci.example.ts.net >/dev/null 2>&1 && ! gitlab --set tailnet.enabled=true --set externalUrl=git-ci.example.ts.net >/dev/null 2>&1
is "a tailnet Ingress refuses an externalUrl without a scheme or with a bad name" "$?"
out="$(helm template b "$repo/bootstrap" --set gitlab.externalUrl=https://git-ci.example.ts.net --set gitlab.lanHost=git.example.test)"
grep -q 'externalUrl: https://git-ci.example.ts.net' <<<"$out" && grep -q 'lanHost: git.example.test' <<<"$out" && grep -q 'enabled: true' <<<"$out"
is "the bootstrap passes the tailnet address, the LAN name and the tailnet switch to GitLab" "$?" "$out"
grep -q 'proxyGroup: ci-proxy' <<<"$out" && grep -q 'name: ci-proxy' <<<"$out"
is "the bootstrap gives GitLab and the operator the same ProxyGroup name" "$?" "$out"
grep -q 'name: tailscale-operator' <<<"$out" && grep -q 'path: apps/tailscale-operator' <<<"$out" && grep -q 'Prune=false,Delete=false' <<<"$out"
is "the bootstrap installs the Tailscale operator and never prunes it" "$?" "$out"

out="$(helm template b "$repo/bootstrap" --show-only templates/storage-provisioner.yaml)"
grep -q 'path: platform/storage-provisioner/democratic-csi' <<<"$out" && grep -q 'name: "nas"' <<<"$out" && grep -q 'defaultClass: true' <<<"$out"   && grep -q 'reclaimPolicy: Delete' <<<"$out" && grep -q 'existingConfigSecret: "truenas-iscsi-ci-driver-config"' <<<"$out" && grep -q 'Prune=false,Delete=false' <<<"$out"
is "the bootstrap makes the default NAS class from the platform chart and never prunes it" "$?" "$out"
! grep -q 'tolerations' <<<"$out"
is "the node plugin has no toleration, so it stays off the privileged node" "$?" "$out"
[ "$(grep -c 'storageClassName: nas$' "$repo/platform-values/observability.yaml")" -eq 4 ]
is "all four observability volumes use the class that the bootstrap makes" "$?"

! helm template b "$repo/bootstrap" --set substrate.enabled=false --set rustfs.enabled=false | grep -q 'substrate\|rustfs'
is "the bootstrap installs no Substrate or RustFS app when both are off" "$?"
out="$(helm template b "$repo/bootstrap" --show-only templates/rustfs.yaml)"
grep -q 'path: platform/rustfs' <<<"$out" && grep -q 'storageClassName: nas' <<<"$out" && grep -q 'name: ci-secrets' <<<"$out" && grep -q 'Prune=false,Delete=false' <<<"$out"
is "RustFS comes from the platform chart on the NAS class, reads its keys from the store and is never pruned" "$?" "$out"
out="$(helm template b "$repo/bootstrap" --set rustfs.storageSize=50Gi --show-only templates/rustfs.yaml)"
grep -q 'storageSize: 50Gi' <<<"$out"
is "the RustFS size is a value of this repo" "$?" "$out"
for app in substrate-prereqs rustfs object-store-bucket substrate-install substrate-workers; do
  helm template b "$repo/bootstrap" --show-only "templates/$app.yaml" | grep -o 'sync-wave: "[0-9]*"'
done | tr -d '
' | grep -q 'sync-wave: "4"sync-wave: "5"sync-wave: "6"sync-wave: "7"sync-wave: "8"'
is "the keys come first, then RustFS, then its bucket, then the Substrate install, then its workers" "$?"
out="$(helm template b "$repo/bootstrap" --set substrate.enabled=true --show-only templates/substrate-install.yaml)"
grep -q 'path: charts/substrate-install' <<<"$out" && grep -q 'profile: s3-compatible' <<<"$out" && grep -q 'type: container_engine_t' <<<"$out"   && grep -q 'secretName: snapshot-store-keys' <<<"$out" && grep -q 'repoURL: "https://github.com/bbaliyan/kube-agent-substrate"' <<<"$out"
is "the Substrate install uses the in-cluster S3 store, a confined SELinux type and the pinned public repo" "$?" "$out"
grep -Eq 'targetRevision: "?[0-9a-f]{40}"?$' <<<"$out" && grep -Eq 'digest: sha256:[0-9a-f]{64}' <<<"$out"
is "the Substrate install pins a commit and an image digest" "$?" "$out"
shim_args="--set substrate.enabled=true --set prAgent.enabled=true --set prAgent.modelEndpoint=http://model.example.test:11434 --set prAgent.namespace=reviews --set prAgent.webhook.port=8080 --show-only templates/substrate-install.yaml"
out="$(helm template b "$repo/bootstrap" $shim_args)"
grep -q 'ingressAllowedSPIFFEIDs: spiffe://cluster.local/ns/reviews/sa/pr-agent-webhook$' <<<"$out"
is "the router allow-list holds the webhook shim identity" "$?" "$out"
out="$(helm template b "$repo/bootstrap" --set substrate.enabled=true --show-only templates/substrate-install.yaml)"
! grep -q ingressAllowedSPIFFEIDs <<<"$out"
is "the router allow-list is not set without the webhook shim" "$?" "$out"
out="$(helm template b "$repo/bootstrap" $shim_args --set substrate.install.helmValues.config.ingressAllowedSPIFFEIDs=spiffe://cluster.local/ns/x/sa/y)"
grep -q 'ingressAllowedSPIFFEIDs: spiffe://cluster.local/ns/reviews/sa/pr-agent-webhook,spiffe://cluster.local/ns/x/sa/y$' <<<"$out"
is "a consumer allow-list is appended to the shim identity" "$?" "$out"
out="$(helm template b "$repo/bootstrap" $shim_args --set prAgent.namespace= 2>&1)"
grep -q 'prAgent.namespace is required' <<<"$out"
is "an empty prAgent.namespace fails when the shim is enabled" "$?" "$out"
out="$(helm template b "$repo/bootstrap" --set substrate.enabled=true --set substrate.install.helmValues.postgres.storage=20Gi --show-only templates/substrate-install.yaml)"
grep -q 'storage: 20Gi' <<<"$out"
is "a consumer value overrides a Substrate install default" "$?" "$out"
out="$(helm template b "$repo/bootstrap" --set substrate.enabled=true --show-only templates/substrate-prereqs.yaml)"
grep -q 'path: apps/substrate-prereqs' <<<"$out" && grep -q 'CreateNamespace=true' <<<"$out"
is "the Substrate prerequisites sync into the control plane namespace" "$?" "$out"

out="$(helm template b "$repo/bootstrap" --set substrate.enabled=true --show-only templates/substrate-workers.yaml)"
grep -q 'path: charts/substrate-workers' <<<"$out" && grep -q 'type: container_engine_t' <<<"$out" && grep -q 'kube-compute.io/node-group: general' <<<"$out"   && grep -q 'replicas: 2' <<<"$out" && grep -q 'cpu: "2"' <<<"$out" && grep -q 'memory: 4Gi' <<<"$out" && grep -q 'namespace: ate-system' <<<"$out"
is "the Substrate workers run two gVisor workers on the general node in the control plane namespace" "$?" "$out"
out="$(helm template b "$repo/bootstrap" --set substrate.enabled=true --set substrate.workers.replicas=4 --set substrate.workers.helmValues.sandboxClass=gvisor --show-only templates/substrate-workers.yaml)"
grep -q 'replicas: 4' <<<"$out"
is "the worker count is a value of this repo" "$?" "$out"
! helm template b "$repo/bootstrap" --set substrate.enabled=false --set rustfs.enabled=true | grep -q 'substrate-workers'
is "RustFS alone installs no Substrate workers" "$?"

# ---- pr-agent --------------------------------------------------------------------------
pr_agent=(--set prAgent.enabled=true --set prAgent.modelEndpoint=http://model.example.test:11434)
for app in substrate-actors substrate-registration substrate-idle-suspend; do
  ! helm template b "$repo/bootstrap" | grep -q "name: $app\$"
  is "pr-agent is off by default: no $app Application" "$?"
done
helm template b "$repo/bootstrap" --show-only templates/substrate-install.yaml | grep -q 'enabled":false'
is "by default the install turns egress credential injection off" "$?"
helm template b "$repo/bootstrap" --show-only templates/substrate-prereqs.yaml | grep -q credentialPolicy \
  && report "by default the prerequisites carry no credential policy" "present" || report "by default the prerequisites carry no credential policy" ok
helm template b "$repo/bootstrap" --show-only templates/first-objects.yaml | grep -q prAgentNamespace \
  && report "by default first-objects makes no pr-agent token" "present" || report "by default first-objects makes no pr-agent token" ok
out="$(helm template b "$repo/bootstrap" --set prAgent.enabled=true 2>&1)"
grep -q 'prAgent.modelEndpoint' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "pr-agent without a model endpoint fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" --set prAgent.enabled=true --set substrate.enabled=false --set prAgent.modelEndpoint=http://model.example.test:11434 2>&1)"
grep -q 'needs substrate.enabled' <<<"$out"
is "pr-agent without Substrate fails the render" "$?" "$out"

for app in substrate-workers substrate-actors substrate-registration substrate-idle-suspend; do
  helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.idleSuspend.enabled=true --show-only "templates/$app.yaml" | grep -o 'sync-wave: "[0-9]*"'
done | tr -d '
' | grep -q 'sync-wave: "8"sync-wave: "9"sync-wave: "10"sync-wave: "11"'
is "the workers come first, then the actor, its registration and the idle suspend" "$?"
! helm template b "$repo/bootstrap" "${pr_agent[@]}" | grep -q 'name: substrate-idle-suspend$'
is "the idle suspend stays off until its switch is on" "$?"

out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/substrate-actors.yaml)"
grep -q 'path: charts/substrate-actor' <<<"$out" && grep -q 'namespace: pr-agent' <<<"$out" && grep -q 'snapshotStorageLocation: objectstore://substrate-snapshots' <<<"$out"
is "the actor chart installs from the pinned Substrate repo into the pr-agent namespace" "$?" "$out"
grep -Eq 'image: pragent/pr-agent:[0-9]+\.[0-9]+\.[0-9]+-gitlab_webhook@sha256:[0-9a-f]{64}$' <<<"$out" && ! grep -q ':latest' <<<"$out"
is "the pr-agent image has a version tag and a digest, never latest" "$?" "$out"
grep -q 'keep_base_url=True); runpy.run_module("gunicorn", run_name="__main__", alter_sys=True)' <<<"$(tr -d '
' <<<"$out" | sed 's/  */ /g')"   && grep -A7 -- '- args:' <<<"$out" | tail -1 | grep -q -- '- pr_agent.servers.gitlab_webhook:app$'
is "the actor keeps GitLab page links on gitlabUrl and runs the gunicorn server of the image" "$?" "$out"
grep -q 'CONFIG__MODEL: ollama/qwen3-coder:30b' <<<"$out" && grep -q "CONFIG__FALLBACK_MODELS: '\[\]'" <<<"$out" && grep -q 'CONFIG__CUSTOM_MODEL_MAX_TOKENS: "16000"' <<<"$out" \
  && grep -q 'CONFIG__DUPLICATE_PROMPT_EXAMPLES: "true"' <<<"$out" && grep -q 'OLLAMA__API_BASE: http://model.example.test:11434' <<<"$out"
is "the model settings follow the model prefix, and the endpoint is the value" "$?" "$out"
grep -q 'credentialUri: ate-secret://k8s.io/default/pr-agent/gitlab-pr-agent/token' <<<"$out" && grep -q 'header: Authorization' <<<"$out" \
  && grep -q 'GITLAB__AUTH_TYPE: oauth_token' <<<"$out" && ! grep -Eq 'glpat-|PERSONAL_ACCESS_TOKEN: [^r]' <<<"$out"
is "the GitLab token is set by the egress proxy from the Secret, and no token is in the values" "$?" "$out"
grep -A3 -- '- hostnames:' <<<"$out" | grep -q 'model.example.test' && grep -q -- '- 11434' <<<"$out"
is "the egress policy allows the host and port of the model endpoint" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.model=ollama/other:7b --set prAgent.contextLength=32000 --show-only templates/substrate-actors.yaml)"
grep -q 'CONFIG__MODEL: ollama/other:7b' <<<"$out" && grep -q 'CONFIG__CUSTOM_MODEL_MAX_TOKENS: "32000"' <<<"$out"
is "the model and the context length are values" "$?" "$out"
grep -q 'CONFIG__OUTPUT_RUN_DETAILS: "true"' <<<"$out"
is "the run details of pr-agent are on by default" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.runDetails=false --show-only templates/substrate-actors.yaml)"
! grep -q 'CONFIG__OUTPUT_RUN_DETAILS' <<<"$out"
is "prAgent.runDetails false leaves the run details setting out" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/substrate-actors.yaml)"
grep -q 'PR_REVIEWER__ENABLE_LARGE_PR_CHUNKING: "true"' <<<"$out" && grep -q 'PR_REVIEWER__MAX_NUMBER_OF_CALLS: "8"' <<<"$out"
is "large reviews are chunked by default, with a cap on the calls" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.largeReviews=false --show-only templates/substrate-actors.yaml)"
! grep -q 'PR_REVIEWER__' <<<"$out"
is "prAgent.largeReviews false leaves the chunking settings out" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.maxReviewCalls=5 --show-only templates/substrate-actors.yaml)"
grep -q 'PR_REVIEWER__MAX_NUMBER_OF_CALLS: "5"' <<<"$out"
is "prAgent.maxReviewCalls is the cap of the calls" "$?" "$out"
grep -q 'CONFIG__AI_TIMEOUT: "600"' <<<"$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/substrate-actors.yaml)"   && grep -q 'CONFIG__AI_TIMEOUT: "300"' <<<"$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.modelTimeoutSeconds=300 --show-only templates/substrate-actors.yaml)"
is "the model timeout defaults to 600 seconds and is a value" "$?" ""
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.maxReviewCalls=abc --show-only templates/substrate-actors.yaml 2>&1)"
grep -q 'maxReviewCalls must be a whole number' <<<"$out"
is "a maxReviewCalls that is not a number fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.modelTimeoutSeconds=abc --show-only templates/substrate-actors.yaml 2>&1)"
grep -q 'modelTimeoutSeconds must be a whole number' <<<"$out"
is "a modelTimeoutSeconds that is not a number fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.model=openai/example-model --set prAgent.modelEndpoint=https://llm.example.test/v1 --set prAgent.egressTrustBundle=true --show-only templates/substrate-actors.yaml)"
grep -q 'CONFIG__MODEL: openai/example-model' <<<"$out" && grep -q 'OPENAI__API_BASE: https://llm.example.test/v1' <<<"$out" && ! grep -q 'OLLAMA__API_BASE' <<<"$out" && ! grep -q 'OPENAI__KEY' <<<"$out"
is "an openai model sets the OpenAI base URL and no Ollama setting, and no key when there is no key Secret" "$?" "$out"
grep -B3 'protocol: https' <<<"$out" | grep -q 'llm.example.test' && grep -B3 'protocol: https' <<<"$out" | grep -q -- '- 443' && [ "$(grep -c 'credentialUri' <<<"$out")" -eq 1 ]
is "an https endpoint gets an https egress rule on port 443 and no credential" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.model=openai/example-model --set prAgent.modelEndpoint=https://llm.example.test --set prAgent.egressTrustBundle=true --set prAgent.modelApiKeySecret.name=model-key --set prAgent.modelApiKeySecret.key=api-key --show-only templates/substrate-actors.yaml)"
grep -Eq 'credentialUri: ate-secret://k8s.io/default/[a-z-]+/model-key/api-key' <<<"$out" && grep -q 'OPENAI__KEY: replaced-by-the-egress-proxy' <<<"$out"
is "a model key Secret is sent by the egress proxy and the actor holds a placeholder only" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.modelEndpoint=http://192.0.2.10:11434 2>&1)"
grep -q 'DNS name, not an IP address' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "a model endpoint that is an IP address fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.modelEndpoint=ftp://model.example.test 2>&1)"
grep -q 'must start with http' <<<"$out"
is "a model endpoint that is not http or https fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.model=other/model 2>&1)"
grep -q 'must start with one of: ollama/, openai/' <<<"$out"
is "a model with an unknown prefix fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.model=openai/example-model --set prAgent.modelEndpoint=https://llm.example.test 2>&1)"
grep -q 'egress gateway CA' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "an https model endpoint without the trust bundle switch fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.gitlabUrl=https://git.example.test 2>&1)"
grep -q 'egress gateway CA' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "an https GitLab address without the trust bundle switch fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.model=openai/example-model --set prAgent.modelEndpoint=https://llm.example.test --set prAgent.egressTrustBundle=true --show-only templates/substrate-actors.yaml)"
missing=0
for setting in SSL_CERT_FILE REQUESTS_CA_BUNDLE GITLAB__SSL_VERIFY; do
  grep -q "$setting: /run/ate/egress-trust-bundle/trust-bundle.pem" <<<"$out" || missing=1
done
[ "$missing" -eq 0 ] && grep -q 'egressTrustBundle: true' <<<"$out"
is "an https address with the switch on gives the actor the trust bundle settings" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/substrate-actors.yaml)"
! grep -q 'SSL_CERT_FILE' <<<"$out" && ! grep -q 'egressTrustBundle' <<<"$out"
is "an http-only actor has no trust bundle settings" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.modelApiKeySecret.name=model-key --set prAgent.modelApiKeySecret.key=api-key --show-only templates/substrate-actors.yaml)"
grep -q 'OLLAMA__API_KEY: replaced-by-the-egress-proxy' <<<"$out" && grep -Eq 'credentialUri: ate-secret://k8s.io/default/[a-z-]+/model-key/api-key' <<<"$out"
is "an ollama model with a key Secret holds a placeholder key and the egress proxy sends the key" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.modelApiKeySecret.name=model-key 2>&1)"
grep -q 'needs a key' <<<"$out" && ! grep -q 'kind: Application' <<<"$out" && ! grep -q 'nil' <<<"$out"
is "a model key Secret with a name and no key fails the render with a clear message" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.modelApiKeySecret.key=api-key 2>&1)"
grep -q 'needs a name' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "a model key Secret with a key and no name fails the render with a clear message" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set 'prAgent.gitlabExtraUrls={https://git.example.test}' --set prAgent.egressTrustBundle=true --show-only templates/substrate-actors.yaml)"
[ "$(grep -c 'gitlab-pr-agent/token' <<<"$out")" -eq 2 ] && grep -q 'git.example.test' <<<"$out" && grep -q -- '- 443' <<<"$out"
is "an extra GitLab address gets its own egress rule with the GitLab token" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set 'prAgent.gitlabExtraUrls={git.example.test}' 2>&1)"
grep -q 'prAgent.gitlabExtraUrls must start with http' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "an extra GitLab address without a scheme fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set 'prAgent.gitlabExtraUrls={http://192.0.2.20}' 2>&1)"
grep -q 'prAgent.gitlabExtraUrls must use a DNS name' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "an extra GitLab address that is an IP address fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set 'prAgent.gitlabExtraUrls={http://gitlab.gitlab.svc.cluster.local}' 2>&1)"
grep -q 'repeats the GitLab host' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "an extra GitLab address that repeats prAgent.gitlabUrl fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set 'prAgent.gitlabExtraUrls={http://model.example.test}' 2>&1)"
grep -q 'same host as prAgent.modelEndpoint' <<<"$out" && ! grep -q 'kind: Application' <<<"$out"
is "an extra GitLab address with the host of the model endpoint fails the render" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.gitlabExtraUrls=null --show-only templates/substrate-actors.yaml 2>&1)"
[ "$(grep -c 'gitlab-pr-agent/token' <<<"$out")" -eq 1 ] && ! grep -q 'nil' <<<"$out"
is "a null list of extra GitLab addresses is an empty list" "$?" "$out"
out="$(helm template b "$repo/bootstrap")"
! grep -q 'pr-agent' <<<"$out" && grep -q 'system:serviceaccount:substrate-system:substrate-registration' <<<"$out"
is "with pr-agent off nothing in the render names pr-agent, and the install keeps its registration owner" "$?" "$out"
! helm template b "$repo/bootstrap" "${pr_agent[@]}" | grep -q 'name: pr-agent-webhook$'
is "with no webhook setting there is no shim app" "$?"
shim=("${pr_agent[@]}" --set prAgent.webhook.port=8080 --set prAgent.hopToken=custom-hop-token)
out="$(helm template b "$repo/bootstrap" "${shim[@]}" --show-only templates/substrate-actors.yaml)"
! grep -qE '^ *webhook:' <<<"$out" && grep -q 'GITLAB__SHARED_SECRET: custom-hop-token' <<<"$out"
is "with the shim on, the actor chart gets no webhook block, so the pinned chart runs no second shim" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${shim[@]}" --show-only templates/pr-agent-webhook.yaml)"
grep -q 'path: apps/pr-agent-webhook' <<<"$out" && grep -q 'namespace: pr-agent$' <<<"$out" && grep -q 'sync-wave: "9"' <<<"$out" \
  && grep -q 'hopToken: custom-hop-token' <<<"$out" && grep -q 'atespace: reviews' <<<"$out" && grep -q 'name: pr-agent$' <<<"$out" && grep -q 'port: 8080' <<<"$out"
is "the shim app syncs with the actor, into its namespace, and sends the hop token that the actor expects" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${shim[@]}" --set prAgent.webhook.hopToken=other-hop-token --show-only templates/pr-agent-webhook.yaml)"
grep -q 'hopToken: custom-hop-token' <<<"$out"
is "a webhook setting cannot split the hop token between the shim and the actor" "$?" "$out"
shim_values="$(helm template b "$repo/bootstrap" "${shim[@]}" --set prAgent.webhook.ingressRoute.enabled=true --set prAgent.webhook.ingressRoute.host=hook.example.test --show-only templates/pr-agent-webhook.yaml \
  | python3 -c 'import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin)["spec"]["source"]["helm"]["valuesObject"]))')"
out="$(helm template pr-agent-webhook "$repo/apps/pr-agent-webhook" --namespace pr-agent -f - <<<"$shim_values" 2>&1)"
grep -q 'replace("x-gitlab-token", "custom-hop-token")' <<<"$out" && grep -q 'replace("ate-target-actor", "reviews/pr-agent")' <<<"$out" \
  && grep -q 'name: pr-agent-webhook$' <<<"$out" && grep -q 'Host(`hook.example.test`)' <<<"$out"
is "the shim chart accepts what the bootstrap passes, and serves the actor that the router allow-list names" "$?" "$out"
! grep -q 'pipeline' <<<"$shim_values"
is "with the pipeline route off, the bootstrap passes no pipeline values" "$?" "$shim_values"
pipeline_values() { # extra helm arguments...
  helm template b "$repo/bootstrap" "${shim[@]}" --set gitlab.externalUrl=https://gitlab.example.test/ --set prAgent.webhook.pipeline.enabled=true "$@" \
    --show-only templates/pr-agent-webhook.yaml | python3 -c 'import sys, yaml; print(yaml.safe_dump(yaml.safe_load(sys.stdin)["spec"]["source"]["helm"]["valuesObject"]))'
}
shim_values="$(pipeline_values)"
out="$(helm template pr-agent-webhook "$repo/apps/pr-agent-webhook" --namespace pr-agent -f - <<<"$shim_values" 2>&1)"
grep -q 'issuer: "https://gitlab.example.test"' <<<"$out" && grep -q 'uri: "http://gitlab.gitlab.svc.cluster.local/oauth/discovery/keys"' <<<"$out" \
  && grep -q 'exact: "mirror"' <<<"$out" && grep -q 'replace("x-gitlab-token", "custom-hop-token")' <<<"$out" \
  && grep -q 'key: x-gitlab-token, value: "custom-hop-token"' <<<"$out"
is "the pipeline route defaults to the external URL as the issuer, the keys at gitlabUrl and the mirror group" "$?" "$out"
shim_values="$(pipeline_values --set firstObjects.helmValues.mirrorGroup=mirrors --set prAgent.webhook.pipeline.issuer=https://other.example.test \
  --set 'prAgent.webhook.pipeline.namespacePaths={team-a,team-b}')"
out="$(helm template pr-agent-webhook "$repo/apps/pr-agent-webhook" --namespace pr-agent -f - <<<"$shim_values" 2>&1)"
grep -q 'issuer: "https://other.example.test"' <<<"$out" && grep -q 'exact: "team-a"' <<<"$out" && grep -q 'exact: "team-b"' <<<"$out" \
  && ! grep -q 'exact: "mirrors"' <<<"$out"
is "pipeline values of the consumer win over the defaults of the bootstrap" "$?" "$out"
shim_values="$(pipeline_values --set firstObjects.helmValues.mirrorGroup=mirrors)"
grep -q -- '- mirrors' <<<"$shim_values"
is "the default allowed group follows the mirror group of first-objects" "$?" "$shim_values"
shim_values="$(pipeline_values --set prAgent.webhook.pipeline.jwksUri=https://gitlab.example.test/oauth/discovery/keys --set prAgent.webhook.pipeline.jwksCa.name=gitlab-ca)"
out="$(helm template pr-agent-webhook "$repo/apps/pr-agent-webhook" --namespace pr-agent -f - <<<"$shim_values" 2>&1)"
grep -q 'address: "gitlab.example.test", port_value: 443' <<<"$out" && grep -q 'trusted_ca: {filename: "/etc/jwks-ca/ca.pem"}' <<<"$out" \
  && grep -q 'matcher: {exact: "gitlab.example.test"}' <<<"$out" && grep -q 'name: gitlab-ca$' <<<"$out"
is "an https key endpoint of an external GitLab is checked against its name and the CA of the ConfigMap" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${shim[@]}" --set 'prAgent.actorHelmValues.actors[0].name=pr-agent' --set 'prAgent.actorHelmValues.actors[0].webhook.port=8080' 2>&1)"
grep -q 'must not set webhook on an actor' <<<"$out"
is "the actor chart values cannot turn on the shim of the actor chart" "$?" "$out"

webhook_args=("${pr_agent[@]}" --set 'prAgent.webhookProjects={mirror/example-repo,mirror/other}' --set prAgent.webhook.port=8080)
! grep -q 'prAgentWebhook' <<<"$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/first-objects.yaml)"
is "by default first-objects makes no webhook" "$?"
out="$(helm template b "$repo/bootstrap" "${webhook_args[@]}" --set prAgent.webhook.port=9000 --show-only templates/first-objects.yaml)"
grep -q 'prAgentWebhookUrl: http://pr-agent-webhook.pr-agent.svc.cluster.local:9000/webhook' <<<"$out" && grep -q 'mirror/example-repo' <<<"$out" && grep -q 'mirror/other' <<<"$out"
is "a webhook project list points first-objects at the shim Service on its port" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set 'prAgent.webhookProjects={mirror/example-repo}' --set prAgent.webhook.allowFrom=null --show-only templates/first-objects.yaml)"
grep -q 'cluster.local:8080/webhook' <<<"$out"
is "the shim port is 8080 when the setting does not name one" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set 'prAgent.webhookProjects={mirror/example-repo}' 2>&1)"
grep -q 'prAgent.webhookProjects needs prAgent.webhook' <<<"$out"
is "a webhook project list without a shim fails the render" "$?" "$out"
out="$(helm template first-objects "$repo/apps/first-objects" --set prAgentNamespace=pr-agent --set prAgentWebhookUrl=http://shim.example.test/webhook --set 'prAgentWebhookProjects={a/b,c/d}' --show-only templates/job.yaml)"
grep -q 'PR_AGENT_WEBHOOK_PROJECTS' <<<"$out" && grep -q 'value: "a/b c/d"' <<<"$out"
is "the Job passes the webhook address and the project paths" "$?" "$out"
! grep -q 'PR_AGENT_WEBHOOK' <<<"$(helm template first-objects "$repo/apps/first-objects" --show-only templates/job.yaml)"
is "by default the Job has no webhook variable" "$?"

out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/substrate-registration.yaml)"
grep -q 'path: charts/substrate-registration' <<<"$out" && grep -q 'name: substrate-registration$' <<<"$out" && grep -q 'namespace: pr-agent' <<<"$out" \
  && grep -Eq 'digest: sha256:[0-9a-f]{64}' <<<"$out" && grep -q 'name: pr-agent' <<<"$out"
is "the registration runs as substrate-registration in pr-agent, the owner that the install names, and pins its image" "$?" "$out"
helm template b "$repo/bootstrap" --show-only templates/substrate-install.yaml "${pr_agent[@]}" | grep -q 'k8s.io' \
  && helm template b "$repo/bootstrap" --show-only templates/substrate-install.yaml "${pr_agent[@]}" | grep -q 'system:serviceaccount:pr-agent:substrate-registration'
is "the install uses the Kubernetes Secrets credential provider and lists the registration account as an owner" "$?"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/substrate-prereqs.yaml)"
grep -q 'credentialPolicy' <<<"$out" && grep -q 'atespace: reviews' <<<"$out" && grep -q 'namespace: pr-agent' <<<"$out"
is "the prerequisites grant the atespace the pr-agent namespace, before the install" "$?" "$out"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --show-only templates/first-objects.yaml)"
grep -q 'prAgentNamespace: pr-agent' <<<"$out"
is "first-objects makes the pr-agent Secret in the pr-agent namespace" "$?" "$out"
for app in substrate-actors substrate-registration substrate-idle-suspend; do
  ! helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.idleSuspend.enabled=true --show-only "templates/$app.yaml" | grep -q CreateNamespace
  is "$app does not create the pr-agent namespace, so first-objects is its only owner" "$?"
done
[ "$(helm template f "$repo/apps/first-objects" --set prAgentNamespace=pr-agent | grep -A8 '^kind: Namespace' | grep -c '  name: pr-agent$')" -eq 1 ]
is "first-objects makes the pr-agent namespace once" "$?"
out="$(helm template b "$repo/bootstrap" "${pr_agent[@]}" --set prAgent.idleSuspend.enabled=true --show-only templates/substrate-idle-suspend.yaml)"
grep -q 'path: charts/substrate-idle-suspend' <<<"$out" && grep -q 'url: http://prometheus-prometheus.prometheus.svc:9090' <<<"$out" && grep -q 'name: pr-agent' <<<"$out" && grep -q 'atespace: reviews' <<<"$out"
is "the idle suspend watches the actor and reads the Prometheus of the platform" "$?" "$out"

# The public repo names no host, address or environment. The model endpoint is a consumer value.
! grep -rEn '(^|[^0-9.])(10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+|\.lan([^A-Za-z]|$)|\.ts\.net' "$repo/bootstrap/values.yaml" "$repo/bootstrap/templates" "$repo/apps/substrate-prereqs" "$repo/apps/first-objects" "$repo/apps/pr-agent-webhook" | grep -v 'git-ci.example.ts.net'
is "no private address or LAN name is in the bootstrap values or templates" "$?"

[ "$failures" -eq 0 ] && echo "all render tests passed" || { echo "$failures render test(s) failed"; exit 1; }
