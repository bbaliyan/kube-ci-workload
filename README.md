# kube-ci-workload

The CI workloads of the homelab `ci` cluster, as Argo CD apps: GitLab, its first objects, and the GitLab Runner. The cluster installs them from `main`, next to [kube-platform](https://github.com/bbaliyan/kube-platform).

## Layout

| Directory | Purpose |
|---|---|
| `bootstrap/` | A Helm chart of Argo CD Applications, one for each app below. Point one Application at it. |
| `apps/gitlab/` | GitLab CE from GitLab's own Docker image, as one StatefulSet. Every default is on. |
| `apps/first-objects/` | A Job that creates the first GitLab objects and the Secrets that the other apps read. |
| `apps/gitlab-runner/` | The GitLab Runner chart with this cluster's settings. |
| `tests/` | Tests for the scripts. |

## How it works

Argo CD installs the apps in this order, one sync wave each:

1. `gitlab`: the StatefulSet, its Service and its Traefik route. The first start takes several minutes.
2. `first-objects`: when GitLab is ready, a Job creates the `mirror` group, a token that pushes to it, a runner and a new root password. It saves them as Secrets and then revokes its own admin token. If the Secrets exist, it does nothing.
3. `gitlab-runner`: the runner reads its token from the Secret.

| Secret | Namespace | Keys | Read by |
|---|---|---|---|
| `gitlab-root` | `gitlab` | `username`, `password` | You, to sign in |
| `gitlab-mirror` | `gitlab` | `token` | The mirror sync |
| `gitlab-runner` | `gitlab-runner` | `runner-token`, `runner-registration-token` | The runner |

The runner and its job pods reach GitLab through the in-cluster Service, so they need no DNS name. People reach the UI at `externalUrl`.

## Use it

The cluster owner creates one Argo CD Application with `path: bootstrap` and this repository. The defaults in `bootstrap/values.yaml` match the homelab. Override a value with `helm.valuesObject`, for example `gitlab.externalUrl`.

The GitLab node is tainted `dedicated=gitlab` and labelled `kube-compute.io/node-group=gitlab`. Nothing else runs there.

To sign in as `root`:

1. Run `kubectl -n gitlab get secret gitlab-root -o jsonpath='{.data.password}' | base64 -d`.
2. Open the address in `gitlab.externalUrl`.
3. Sign in as `root` with that password.

## Upgrade GitLab

GitLab has required upgrade stops. Move one minor release at a time. Renovate opens the PR but does not merge it.

1. Read [the upgrade paths](https://docs.gitlab.com/update/upgrade_paths/) for the next stop.
2. Change `image.tag` in `apps/gitlab/values.yaml` to that release.
3. Change the `gitlab-runner` chart version in `apps/gitlab-runner/Chart.yaml` to the matching minor release.
4. Merge the PR. Argo CD replaces the pod, and GitLab migrates its database on start.

## Checks

`make test-commit` runs every check in the pinned `kube-devenv` image. GitHub runs it as the `commit` check on every pull request and every push to `main`. The mirror on GitLab runs it too.

| Command | What it does |
|---|---|
| `make test-fast` | Runs the secret scan. Run `make hooks` once to run it before each commit. |
| `make charts` | Lints and renders each chart, then validates it against the Kubernetes and CRD schemas. Needs network access. |
| `make test-scripts` | Tests `first-objects.sh` with stand-ins for kubectl, curl and GitLab. |
| `make test-integration` | Installs the apps on a real cluster (`KUBECONFIG`), checks what the Job made, and waits for a pipeline to pass on the runner. It uses two scratch namespaces that end in `-it` and deletes them. Not part of `test-commit`. It needs kubectl, helm and jq. |

## Related repos

- `../kube-homelab`: builds the `ci` cluster and tells Argo CD about this repo.
- `../kube-platform`: the platform that this repo builds on (Traefik, storage, Argo CD).
