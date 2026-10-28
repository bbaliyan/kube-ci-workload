# kube-ci-workload

The CI workloads of the homelab `ci` cluster, as Argo CD apps. The cluster installs them next to [kube-platform](https://github.com/bbaliyan/kube-platform).

| Directory | Purpose |
|---|---|
| `bootstrap/` | A Helm chart of Argo CD Applications, one per app, in sync waves. |
| `apps/gitlab/` | GitLab CE from GitLab's Docker image, as one StatefulSet. |
| `apps/first-objects/` | A Job that creates the first GitLab objects and the Secrets below. |
| `apps/gitlab-runner/` | The GitLab Runner chart. |
| `apps/mirror-sync/` | One pod that mirrors GitHub repositories into the `mirror` group every 60 seconds. |
| `apps/tailscale-operator/` | The Tailscale operator and the ProxyGroup that serves the tailnet names. |

## Secrets

| Secret | Namespace | Keys | Made by |
|---|---|---|---|
| `gitlab-root` | `gitlab` | `username`, `password` | `first-objects` |
| `gitlab-mirror` | `gitlab` | `token` | `first-objects` |
| `gitlab-runner` | `gitlab-runner` | `runner-token`, `runner-registration-token` | `first-objects` |
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

## Upgrade GitLab

GitLab has required upgrade stops. Move one minor release at a time. Renovate opens the PR and does not merge it.

1. Read [the upgrade paths](https://docs.gitlab.com/update/upgrade_paths/).
2. Change `image.tag` in `apps/gitlab/values.yaml`.
3. Change the `gitlab-runner` chart version in `apps/gitlab-runner/Chart.yaml` to the matching minor release.
4. Merge the PR.

## Checks

`make test-commit` runs every check in the pinned `kube-devenv` image. It is the `commit` check on GitHub and on the GitLab mirror. `make test-integration` installs the apps on a real cluster (`KUBECONFIG`) and is not part of it.
