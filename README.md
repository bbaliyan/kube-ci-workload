# kube-ci-workload

The CI workloads of the homelab `ci` cluster, as Argo CD apps. The cluster installs them next to [kube-platform](https://github.com/bbaliyan/kube-platform).

| Directory | Purpose |
|---|---|
| `bootstrap/` | A Helm chart of Argo CD Applications, one per app, in sync waves. |
| `apps/gitlab/` | GitLab CE from GitLab's Docker image, as one StatefulSet. |
| `apps/first-objects/` | A Job that creates the first GitLab objects and the Secrets below. |
| `apps/gitlab-runner/` | The GitLab Runner chart. |
| `apps/mirror-sync/` | One pod that mirrors GitHub repositories into the `mirror` group every 60 seconds. |
| `apps/pipeline-exporter/` | Exports the status and durations of the mirrored projects' pipelines to Prometheus. |
| `apps/ci-monitoring/` | The KPI rules and the Grafana dashboards. |
| `apps/tailscale-operator/` | The Tailscale operator and the ProxyGroup that serves the tailnet names. |
| `platform-values/` | Settings for the platform components of the cluster. See below. |

## Secrets

| Secret | Namespace | Keys | Made by |
|---|---|---|---|
| `gitlab-root` | `gitlab` | `username`, `password` | `first-objects` |
| `gitlab-mirror` | `gitlab` | `token` | `first-objects` |
| `gitlab-exporter` | `gitlab` | `gitlabToken` | `first-objects` |
| `gitlab-runner` | `gitlab-runner` | `runner-token`, `runner-registration-token` | `first-objects` |
| `gitlab-pr-agent` | `prAgent.namespace` | `token`, `WEBHOOK_SECRET` (only with `prAgent.enabled`) | `first-objects` |
| `truenas-iscsi-ci-driver-config` | `kube-system` | `driver-config-file.yaml` (democratic-csi driver config) | the consumer |
| `github-source` | `gitlab` | `token` (read-only GitHub token) | the consumer |
| `operator-oauth` | `tailscale` | `client_id`, `client_secret` | the consumer |

## Use it

Point one Argo CD Application at `bootstrap/` and override the placeholders in `bootstrap/values.yaml`:

- `gitlab.externalUrl`: `https://git-ci.<tailnet>.ts.net`. GitLab builds its links from it, and the tailnet host name is its first label.
- `gitlab.lanHost`: an optional plain HTTP route on the LAN. Sign-in does not work on it.
- `mirrorSync.helmValues`: `sourceBase` and `repos`.

The tailnet policy needs:

- `tag:ci`, owned by the operator.
- An `autoApprovers.services` entry for `svc:git-ci` with `tag:ci`.
- A grant to `svc:git-ci` on `tcp:443`.
- The Services write scope on the operator's OAuth client.

To sign in as `root`:

1. Run `kubectl -n gitlab get secret gitlab-root -o jsonpath='{.data.password}' | base64 -d`.
2. Open the address in `gitlab.externalUrl` and sign in as `root`.

## Storage

The bootstrap makes the storage class `nas`, the default class, with democratic-csi on a NAS over iSCSI. The class deletes a volume when its claim goes. The node plugin has no toleration, so it does not run on the privileged node, which is tainted and would give it the NAS API key. Change the names in `storageProvisioner` in `bootstrap/values.yaml`.

## The platform-values/ directory

`platform-values/observability.yaml` sets the size, class and retention of Prometheus, Alertmanager, Grafana and Loki. The platform `observability` Application reads it when the cluster passes this repo as its workloads repo. A merge to `main` reaches the cluster at the next sync.

## pr-agent

pr-agent reviews merge requests. It runs as an Agent Substrate actor and uses a model that runs outside the cluster. It is off by default. It needs `substrate.enabled`.

The bootstrap makes these parts when `prAgent.enabled` is true:

| Part | Wave | What it does |
|---|---|---|
| `first-objects` | 1 | Makes the Secret `gitlab-pr-agent` in `prAgent.namespace`: a Developer group token and a random webhook secret. |
| `substrate-prereqs` | 4 | Makes the credential policy that lets the atespace read Secrets of `prAgent.namespace` only. |
| `substrate-install` | 7 | Turns on the Kubernetes Secrets credential provider. |
| `substrate-actors` | 9 | Defines the actor: the pinned `gitlab_webhook` image, the model settings and the egress policy. |
| `substrate-registration` | 10 | Registers the actor in the control plane. |
| `substrate-idle-suspend` | 11 | Suspends the idle actor. It has its own switch and is off. |

The actor never holds the GitLab token. Its egress policy lets only the GitLab host and the model endpoint through, and the egress proxy sets the `Authorization` header from the Secret.

### Enable it

The actor talks to a model server that runs outside the cluster. The consumer sets the model, the address of the server and, if the server has a login, the Secret that holds its key.

1. Set `prAgent.model` to a model name of pr-agent. The prefix must be `ollama/` or `openai/`. Use `openai/` for any server with an OpenAI-compatible API.
2. Set `prAgent.modelEndpoint` to the base URL of the server. Use a DNS name, not an IP address, because the egress policy matches host names. If you do not set it, the render fails.
3. If the server has a login, create a Secret in `prAgent.namespace` and set `prAgent.modelApiKeySecret` to its `name` and `key`. The egress proxy sends the key as a bearer token, so the actor never holds it.
4. Set `prAgent.contextLength` to the context length of the server, in tokens. The two numbers must be equal.
5. Set `prAgent.enabled` to `true` and sync the bootstrap.
6. Verify that the Applications `substrate-actors` and `substrate-registration` are Healthy.

Example for Ollama on a laptop:

1. On the model host, run `ollama pull qwen3-coder:30b`.
2. On the model host, start Ollama with `OLLAMA_HOST=0.0.0.0` and `OLLAMA_CONTEXT_LENGTH=16000`.
3. Set `prAgent.modelEndpoint` to `http://<host name>:11434`.

Warning: Ollama has no login. Make it reachable from the LAN only.

The model and the endpoint are values, so no model name or address is in this repo. A model that runs on a laptop is good enough to test the wiring. It may not give good reviews.

### Not done yet

- The webhook shim. GitLab cannot reach a suspended actor, so a small service must receive the webhook, check the secret in `gitlab-pr-agent` and send the request to the actor. No such image is published. When you have one, set `prAgent.webhook` (image by digest, port, ingress). The shim must send the value of `prAgent.sharedSecret` in `X-Gitlab-Token`, because pr-agent refuses a request without its shared secret.
- The GitLab webhook. After the mirror sync has made the project, add a project webhook with the address of the shim and the value of `WEBHOOK_SECRET`. If the shim runs in the cluster, an administrator must allow webhooks to local addresses.
- The idle suspend. To turn it on, set `prAgent.idleSuspend.enabled`. Prometheus must scrape the control plane. A cluster administrator must give the service account `substrate-idle-suspend` the `editor` role in the atespace with `kubectl ate update access-policy`.

### Renew the token

The group token lives for 364 days. `first-objects` never replaces a Secret that exists. To renew the token:

1. Delete the Secret `gitlab-pr-agent` in `prAgent.namespace`.
2. Sync `first-objects`.
3. Revoke the old token in the group settings of GitLab.

## Upgrade GitLab

GitLab has required upgrade stops. Move one minor release at a time. Renovate opens the PR and does not merge it.

1. Read [the upgrade paths](https://docs.gitlab.com/update/upgrade_paths/).
2. Change `image.tag` in `apps/gitlab/values.yaml`.
3. Change the `gitlab-runner` chart version in `apps/gitlab-runner/Chart.yaml` to the matching minor release.
4. Merge the PR.

## Checks

`make test-commit` runs every check in the pinned `kube-devenv` image. The KPI rules have tests in `tests/kpis.test.yaml` (promtool), and each chart has declared tests in its `tests/` folder (helm-unittest). It is the `commit` check on GitHub and on the GitLab mirror. `make test-integration` installs the apps on a real cluster (`KUBECONFIG`) and is not part of it.
