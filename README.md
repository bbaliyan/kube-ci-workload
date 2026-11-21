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
| `apps/pr-agent-webhook/` | The GitLab webhook shim of pr-agent: an Envoy that checks the webhook secret and calls the actor. |
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
| `first-objects` | 1 | Makes the namespace `prAgent.namespace` and the Secret `gitlab-pr-agent` in it: a Developer group token and a random webhook secret. With `prAgent.webhookProjects`, it also makes the project webhooks. It is the only owner of the namespace. |
| `substrate-prereqs` | 4 | Makes the credential policy that lets the atespace read Secrets of `prAgent.namespace` only. |
| `substrate-install` | 7 | Turns on the Kubernetes Secrets credential provider. |
| `substrate-actors` | 9 | Defines the actor: the pinned `gitlab_webhook` image, the model settings and the egress policy. |
| `pr-agent-webhook` | 9 | Runs the webhook shim. Only with `prAgent.webhook`. |
| `substrate-registration` | 10 | Registers the actor in the control plane. |
| `substrate-idle-suspend` | 11 | Suspends the idle actor. It has its own switch and is off. |

The actor never holds the GitLab token. Its egress policy lets only the GitLab host and the model endpoint through, and the egress proxy sets the `Authorization` header from the Secret.

### Enable it

The actor talks to a model server that runs outside the cluster. The consumer sets the model, the address of the server and, if the server has a login, the Secret that holds its key.

1. Set `prAgent.model` to a model name of pr-agent. The prefix must be `ollama/` or `openai/`.
2. For any server with an OpenAI-compatible API, use the prefix `openai/`.
3. Set `prAgent.modelEndpoint` to the base URL of the server. If you do not set it, the render fails.
4. Use a DNS name, not an IP address, because the egress policy matches host names.
5. If the address is `https`, set `prAgent.egressTrustBundle` to `true`. The `substrate-actor` chart of `substrate.revision` must accept that key. If it does not, the render fails.
6. If the server has a login, create a Secret in `prAgent.namespace` that holds its key.
7. Set `prAgent.modelApiKeySecret` to the `name` and the `key` of that Secret.
8. Set `prAgent.contextLength` to the context length of the server, in tokens. The two numbers must be equal.
9. Set `prAgent.enabled` to `true`. Each review, description and suggestion comment of pr-agent then ends with a run details section: the model, the tokens, the time cost and the number of model calls. Set `prAgent.runDetails` to `false` to turn it off.
   When whole files do not fit in `prAgent.contextLength`, the review is split into chunks, one model call each, and the results are merged into one review. A diff that fits takes one call. The chunk size follows `contextLength`, so there is nothing else to tune. The chunk calls of one review run at the same time, and an MR event also starts `/describe` and `/improve`, which split large diffs on their own. `prAgent.maxReviewCalls` (default 20) caps the chunk calls of one review. The calls go out at the same time, so the cap keeps the burst of one MR event (these calls, `/describe` and `/improve`) under the request rate of the model server. A diff that needs more calls lists the files it did not reach. A chunk whose call fails is only counted in the review: its files are not named, so a review that says a chunk failed is not complete. Set `prAgent.largeReviews` to `false` to review only what fits in one call. `prAgent.modelTimeoutSeconds` (default 600) is how long pr-agent waits for one model call. Raise it for a server that queues calls.
10. Sync the bootstrap.
11. Verify that the Applications `substrate-actors` and `substrate-registration` are Healthy.

The egress proxy sends the key as a bearer token, so the actor never holds it. For both prefixes, the actor holds only a placeholder in `OLLAMA__API_KEY` or `OPENAI__KEY`. For `ollama/`, verify with one review that the Ollama client of pr-agent sends the header.

Example for Ollama on a laptop:

1. On the model host, run `ollama pull qwen3-coder:30b`.
2. On the model host, start Ollama with `OLLAMA_HOST=0.0.0.0` and `OLLAMA_CONTEXT_LENGTH=16000`.
3. Set `prAgent.modelEndpoint` to `http://<host name>:11434`.

Warning: Ollama has no login. Make it reachable from the LAN only.

The model and the endpoint are values, so no model name or address is in this repo. A model that runs on a laptop is good enough to test the wiring. It may not give good reviews.

### Not done yet

- The idle suspend. To turn it on, set `prAgent.idleSuspend.enabled`. Prometheus must scrape the control plane. A cluster administrator must give the service account `substrate-idle-suspend` the `editor` role in the atespace with `kubectl ate update access-policy`.

### The webhook shim

GitLab cannot reach a suspended actor, so it calls the shim, and the shim calls the router of the control plane. The router wakes the actor. The chart is `apps/pr-agent-webhook`. The shim:

- Checks `X-Gitlab-Token` against the key `WEBHOOK_SECRET` of the Secret `gitlab-pr-agent`. A wrong or missing token gets a 401.
- Replaces the token with `prAgent.hopToken`, which the actor expects as its shared secret.
- Sets the header `ate-target-actor` to `<prAgent.atespace>/pr-agent`.
- Calls the router over mTLS with the certificate of its service account, `pr-agent-webhook`.
- Tries again after a refused connection, a 502, a 503, a 504 or a try that runs out of time. By default, it makes 3 tries of 60 seconds and waits 190 seconds in total.

The router allow-list `config.ingressAllowedSPIFFEIDs` is set to the shim identity, `spiffe://cluster.local/ns/<prAgent.namespace>/sa/pr-agent-webhook`. To allow more callers, set `substrate.install.helmValues.config.ingressAllowedSPIFFEIDs` to a comma-separated list. It is added to the shim identity.

To turn on the shim, set `prAgent.webhook`. Its keys are values of `apps/pr-agent-webhook/values.yaml`, for example `{port: 8080}`. The bootstrap always sets `actor` and `hopToken`, so the shim and the actor agree.

| Key | Default | Meaning |
|---|---|---|
| `port` | `8080` | The port of the shim and its Service. |
| `retries` | `2` | Tries after the first one. `0` turns the retries off. |
| `perTryTimeoutSeconds` | `60` | The time of one try. |
| `timeoutSeconds` | `190` | The time of all tries. It must be at least `(retries + 1) x perTryTimeoutSeconds + retries x 5`, or the render fails. |
| `allowFrom` | `[]` | The `from` entries of a NetworkPolicy on the shim port. Empty makes no policy. |
| `ingressRoute.enabled` | `false` | Makes a Traefik IngressRoute for a sender outside the cluster. |
| `ingressRoute.host` | none | The host name of the route. It is required when the route is on. |
| `ingressRoute.entryPoints` | `[websecure]` | The Traefik entry points. |
| `ingressRoute.tlsSecretName` | none | The TLS Secret of the route. Without it, Traefik serves its default certificate. |

If you set `allowFrom` and `ingressRoute`, add the namespace of Traefik to `allowFrom`.

The real secret stays in the Secret. The pod mounts it as a file, and the shim reads the file on every request, so a new value takes effect after the kubelet refreshes the mount. An empty file or a file of white space only refuses every request. The hop token is public. The router allow-list guards the last hop, not the hop token.

#### Start, resume and lost deliveries

- A new actor starts suspended, and its first start takes about 15 seconds. A later resume is fast. While the router starts an actor, it can answer 502 or 504.
- A retry after a 502 or a 504 can deliver one webhook twice, and a cold start makes that likely. A second review is a smaller loss than a lost review.
- The shim stops its request when the sender leaves. If GitLab gives up before the router answers, the delivery is lost. GitLab.com documents a webhook timeout of 10 seconds. On a self-managed GitLab, raise `gitlab_rails['webhook_timeout']` above `timeoutSeconds`.
- GitLab counts failed deliveries. After four failures in a row, it disables the webhook for a while. After 40, it disables it for good.
- The probes use `/healthz`, which the shim answers itself. A pod with a broken client certificate is still Ready, and the first delivery shows the fault as a 503.
- The shim runs one pod with no PodDisruptionBudget. A node drain stops it for a short time.

#### What `make test-shim` verifies

The test renders the chart and runs the shim in Docker, as a non-root user on a read-only file system, against a stand-in router that needs a client certificate. It verifies the token rules (a missing, wrong, extended or empty token, and an empty, blank, rotated or missing secret file), the hop token and the target header, the retries after a 502, a 504 and a try that runs out of time, a sender that leaves early, a router certificate for another name and a client certificate from an unknown CA.

It does not cover the real router, a real pod certificate signer, the certificate rotation of the kubelet, the back-off time or a retry after a refused connection.

For the pipeline route, the test signs ID tokens with a local RSA key pair and serves the public key from a stand-in key endpoint. It verifies that a valid token reaches the actor at `/webhook` with the hop token and without the Authorization header, and that a token of a listed subgroup passes. It verifies that the route refuses a request with no token, with the webhook secret only, with a wrong signature, audience or issuer, an expired token, a token without an expiry time, a token of another group and a token of a branch pipeline. It verifies that a valid token does not open the webhook route, that a key fetch over HTTPS with the CA of `pipeline.jwksCa` works, and that a shim whose key endpoint is down refuses a valid token with a 401. It does not cover a real GitLab or a key rotation.

### Reviews from a pipeline

A CI job can ask for a review without the webhook secret and without a GitLab webhook. The job gets an ID token from GitLab (`id_tokens:`) and sends it to the pipeline route of the shim. GitLab issues the token, so the job can run on any runner, in the cluster or outside it, if the runner can reach the route.

The shim:

- Verifies the signature of the token against the keys of GitLab, and verifies the issuer, the audience and the expiry time. A failed check gets a 401, and a token for another audience gets a 403.
- Verifies two claims: `namespace_path` must be in `pipeline.namespacePaths`, and `pipeline_source` must be `merge_request_event`. A failed check gets a 403.
- Removes the token, sets the hop token and `ate-target-actor`, and calls the actor at `/webhook`, with the retries of the webhook route.

The route is off by default. It does not change the webhook route, which still needs `X-Gitlab-Token`.

| Key | Default | Meaning |
|---|---|---|
| `pipeline.enabled` | `false` | Turns on the route. |
| `pipeline.path` | `/pipeline` | The path of the route. |
| `pipeline.issuer` | none | The external URL of GitLab, with no trailing slash. It must equal the `iss` claim. |
| `pipeline.audiences` | `[pr-agent]` | The `aud` claims that the shim accepts. |
| `pipeline.jwksUri` | none | The key endpoint: `<GitLab URL>/oauth/discovery/keys`. |
| `pipeline.jwksCacheSeconds` | `300` | How long the shim keeps the keys. |
| `pipeline.jwksCa` | `{name: "", key: ca.crt}` | For an https key endpoint: a ConfigMap and key that hold the CA of GitLab. An empty name uses the CA bundle of the Envoy image. |
| `pipeline.namespacePaths` | `[]` | The full paths of the groups whose pipelines may ask for a review. A subgroup needs its own entry. |

With `prAgent.webhook.pipeline.enabled`, the bootstrap sets the defaults from this GitLab: `gitlab.externalUrl` is the issuer, the key endpoint is under `prAgent.gitlabUrl`, and the mirror group of first-objects is the only group. Values in `prAgent.webhook.pipeline` win over these defaults. A runner outside the cluster also needs `ingressRoute`. If you set `allowFrom`, add the namespace of the in-cluster runner jobs too, or the policy blocks them. A runner outside the cluster comes in through Traefik, so it needs the Traefik entry.

The keys decide which tokens pass, so the shim must get them from the real GitLab. The default key endpoint is the GitLab Service over plain HTTP. It trusts the cluster network, as the other in-cluster calls to GitLab do. For a GitLab outside the cluster, set `pipeline.jwksUri` to its https address. The shim then verifies the certificate against the host name and the CA of `pipeline.jwksCa`, or the CA bundle of the image.

The shim fetches the keys when it starts and again before the cache runs out. If the key endpoint is down, the shim has no keys and refuses every token with a 401. It tries again every 10 seconds. A token must carry an expiry time (`exp`). GitLab always sets it.

#### The job

The job sends a comment event with the command, as GitLab does for a comment. pr-agent 0.50.0 needs these fields: `object_kind` and `event_type` set to `note`, `merge_request.url` and `object_attributes.note`. `user.id` and `user.username` are optional. They name the person who started the pipeline.

A real comment event also has `object_attributes.id`, the ID of the comment. pr-agent puts its start reaction on that comment, and without the ID the command fails. The job has no comment, so it turns the reaction off with `--config.reaction_on_start=` in the command.

The answer is 200 when the actor accepted the event. The review then runs in the actor and appears on the merge request a little later. This job fails only if the request is refused. To fail the job on a failed or incomplete review, use the gate below.

```yaml
pr-agent-review:
  image:
    name: curlimages/curl:8.11.1
    entrypoint: [""]
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
  id_tokens:
    PR_AGENT_ID_TOKEN:
      aud: pr-agent
  script:
    - >
      printf '{"object_kind":"note","event_type":"note","user":{"id":%s,"username":"%s"},"merge_request":{"url":"%s/-/merge_requests/%s"},"object_attributes":{"note":"/review --config.reaction_on_start="}}'
      "$GITLAB_USER_ID" "$GITLAB_USER_LOGIN" "$CI_MERGE_REQUEST_PROJECT_URL" "$CI_MERGE_REQUEST_IID" > event.json
    - >
      curl --fail-with-body -sS -m 200 -H "Authorization: Bearer $PR_AGENT_ID_TOKEN"
      -H "Content-Type: application/json" --data-binary @event.json https://pr-agent.example.com/pipeline
```

On a Windows runner with the PowerShell shell, the script is:

```yaml
  script:
    - |
      $event = @{
        object_kind = 'note'; event_type = 'note'
        user = @{ id = [int]$env:GITLAB_USER_ID; username = $env:GITLAB_USER_LOGIN }
        merge_request = @{ url = "$env:CI_MERGE_REQUEST_PROJECT_URL/-/merge_requests/$env:CI_MERGE_REQUEST_IID" }
        object_attributes = @{ note = '/review --config.reaction_on_start=' }
      } | ConvertTo-Json -Depth 3
      Invoke-RestMethod -Method Post -Uri https://pr-agent.example.com/pipeline -TimeoutSec 200 `
        -ContentType application/json -Headers @{ Authorization = "Bearer $env:PR_AGENT_ID_TOKEN" } -Body $event
```

#### The gate

The example `examples/pr-agent-review-gate/` makes the job wait for the review and fail the pipeline if the review is not complete. It has the job (`gitlab-ci.yml`), the script (`pr-agent-gate.py`, Python standard library only, so it runs on a Linux and on a Windows runner) with a self-test of the decision logic (`pr-agent-gate-test.sh`, with saved review notes in `fixtures/`).

The job:

1. Sends the same request as above and records the time.
2. Polls the notes of the merge request every `PR_AGENT_POLL_SECONDS` (default 20 seconds), for up to `PR_AGENT_WAIT_MINUTES` (default 25 minutes). It looks for a note of the review bot that is newer than the request and contains `PR Reviewer Guide` or `Failed to review PR`. A note that says `Preparing review` is progress and is ignored.
3. Prints the chunk line and the run details (model, tokens, time cost, AI calls) into the job log.
4. Fails if the final note says `chunk(s) failed`, `Failed to review PR` or `were not included in this review`. It also fails if no final note appears in time, or if pr-agent refuses the request. Otherwise it passes.

The job reads the notes with the job token (`CI_JOB_TOKEN`). Verify that your GitLab version lets the job token read `GET /projects/:id/merge_requests/:iid/notes`. If it does not, store a project access token with the scope `read_api` and the role Reporter in a masked CI variable, and send it in the `PRIVATE-TOKEN` header instead. `GITLAB_API_URL` must be an address that the job pod can reach.

Run `python3 examples/pr-agent-review-gate/pr-agent-gate.py --self-test` to test the logic offline. `make test-scripts` runs it.

The job is made for a small in-cluster runner that has the tag `commit`. The review runs in the actor, so the job only waits. It needs a small pod, and `needs: []` lets it run next to the other jobs. The job sets the pod size with the variables `KUBERNETES_CPU_REQUEST`, `KUBERNETES_CPU_LIMIT`, `KUBERNETES_MEMORY_REQUEST` and `KUBERNETES_MEMORY_LIMIT`. The Kubernetes executor ignores these variables unless the runner config sets a ceiling for each one. If a ceiling is missing, the job gets the default pod size of the runner. Set the ceilings in the `[runners.kubernetes]` block of the runner:

```toml
cpu_request_overwrite_max_allowed = "200m"
cpu_limit_overwrite_max_allowed = "200m"
memory_request_overwrite_max_allowed = "128Mi"
memory_limit_overwrite_max_allowed = "128Mi"
```

#### What a GitLab of your IT department must give

- ID tokens: the `id_tokens` keyword, GitLab 15.7 or later.
- A key endpoint that the shim can reach: `/oauth/discovery/keys` under the external URL, or under an internal address that serves the same keys. The issuer is always the external URL.
- CA trust on the shim: if a private CA signs the GitLab certificate, put the CA in a ConfigMap and set `pipeline.jwksCa`.
- CA trust on the runners: the runners must trust the certificate of the ingress route. Put the CA in the job image, pass it to curl with `--cacert`, or add it to the machine store of a Windows runner.
- Network: the runners must reach the ingress route, and the shim must reach the key endpoint.
- The pr-agent token: the actor still reads the merge request with its own GitLab token, so that token must have access to each project.

#### Limits

- The claims bind the request to a group only. The shim does not read the body, so the job controls the whole event. A job in an allowed group can run any pr-agent command, such as `/improve` or `/ask`, with any `--config.*` override that pr-agent accepts in a comment. It can name any merge request that the pr-agent token can read, and any `user` fields. Allow only groups whose CI files you trust.
- The shim keeps the keys for `jwksCacheSeconds`. After GitLab rotates its keys, a token with a new key can fail until the cache expires.

The `substrate-actor` chart of the pinned `substrate.revision` can still run a shim of its own, with the same names. The bootstrap never gives it a `webhook` block, and the render fails if `prAgent.actorHelmValues` sets one.

### The GitLab webhook

GitLab sends merge request events and comment events to the shim. A comment event carries a command such as `/review`. The webhook has no push events.

With GitLab in the cluster, `first-objects` makes the webhook:

1. Set `prAgent.webhook`, so the bootstrap runs the shim.
2. Set `prAgent.webhookProjects` to the paths of the projects, for example `mirror/kube-compute`.
3. Sync `first-objects` after the mirror sync has made the projects. A project that does not exist yet is skipped with a warning, and the next run makes its webhook.

The webhook points at `http://pr-agent-webhook.<prAgent.namespace>.svc.cluster.local:<port>/webhook`. The port is `prAgent.webhook.port`, or 8080. Its secret token is `WEBHOOK_SECRET` of the Secret `gitlab-pr-agent`.

Warning: the Job sets the instance setting `allow_local_requests_from_web_hooks_and_services` to `true`. It is an administrator setting for the whole GitLab, not for one project. It lets every webhook and integration call local addresses. Set `prAgent.webhookProjects` only if you accept that.

Every run writes the full settings of the webhook again. The GitLab API does not return the secret token, so a run cannot see if it changed. This also repairs a hook that someone edited and picks up a renewed secret. A run never makes a second hook for the same address.

The API has no timeout for one webhook. The limit is `gitlab_rails['webhook_timeout']` in `gitlab.rb` of a self-managed GitLab, and `first-objects` cannot set it. If GitLab gives up before the shim answers, raise it there.

With GitLab outside the cluster, turn on `prAgent.webhook.ingressRoute`, leave `prAgent.webhookProjects` empty and make the webhook by hand:

1. In the project, open Settings, then Webhooks.
2. Set the URL to the address of the shim, with the path `/webhook`.
3. Set the secret token to the value of `WEBHOOK_SECRET`.
4. Select the triggers Merge request events and Comments only.
5. If the URL is https with a certificate that GitLab trusts, keep SSL verification on.

### Renew the token

The group token has the Developer role and the `api` scope. The command `/describe` edits the title and the description of a merge request, and a Reporter cannot do that. It lives for 364 days. `first-objects` never replaces a Secret that exists. To renew the token:

1. Delete the Secret `gitlab-pr-agent` in `prAgent.namespace`.
2. Sync `first-objects`.

`first-objects` revokes the active `pr-agent` tokens of the group when the Secret is missing, then makes a new token. This also covers a run that made a token and could not save the Secret.

### Long lists

GitLab builds the links to the next page of a long list (an MR with more than 100 notes, diffs or discussions, the page size of pr-agent 0.50.0) from its external URL. python-gitlab follows those links, and pr-agent 0.50.0 has no setting to keep the base URL. The egress policy allows only `prAgent.gitlabUrl`, so such a call can be blocked. If a review of a large MR fails, add the external URL of GitLab to `prAgent.gitlabExtraUrls`. The egress proxy then sets the token for that host too.

## Upgrade GitLab

GitLab has required upgrade stops. Move one minor release at a time. Renovate opens the PR and does not merge it.

1. Read [the upgrade paths](https://docs.gitlab.com/update/upgrade_paths/).
2. Change `image.tag` in `apps/gitlab/values.yaml`.
3. Change the `gitlab-runner` chart version in `apps/gitlab-runner/Chart.yaml` to the matching minor release.
4. Merge the PR.

## Checks

`make test-commit` runs every check in the pinned `kube-devenv` image. The KPI rules have tests in `tests/kpis.test.yaml` (promtool), and each chart has declared tests in its `tests/` folder (helm-unittest). It is the `commit` check on GitHub and on the GitLab mirror. `make test-integration` installs the apps on a real cluster (`KUBECONFIG`) and is not part of it. `make test-shim` runs the webhook shim in Docker against a stand-in router that needs a client certificate. It needs Docker on the host, so it is the `shim` check on GitHub and is not part of `test-commit`.
