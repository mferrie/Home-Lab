# ArgoCD to Flux Migration (started 10/29/2026)

## Rationale

I decided to switch my GitOps pipeline from ArgoCD to Flux because I read that Flux uses fewer resources and that a CLI-driven workflow is more efficient than a GUI. (Flux has no built-in UI, so everything below is done with `flux`, `kubectl` and Git.)

## Status (as of 8 PM, 10/29)

| App | Type | Status |
|---|---|---|
| flux-system | bootstrap | Ready (after path fix, see Problems) |
| forgejo | Helm | Migrated, working |
| homepage | plain manifests | Migrated, Ready |
| grafana | plain manifests | Kustomization exists and is NOT suspended. Confirm the Argo app was deleted non-cascading |
| joplin | plain manifests | Next |
| searxng, mealie, vaultwarden, pihole-unbound | plain manifests | Pending (suspended in `apps.yaml`) |
| loki, tempo, prometheus | Helm (namespace `lgtm`) | Pending |
| nextcloud | Helm | Pending |
| immich | Helm + plain manifests | Pending, do last |
| metallb, cert-manager, longhorn (config only) | plain manifests | Pending, do last |

Progress tracking: every Kustomization in `apps.yaml` starts with `suspend: true`, so `grep "suspend: true" k3s/flux-system/apps.yaml` lists what is left.

## Setup

### Audit

Following [this guide](https://oneuptime.com/blog/post/2026-01-27-argocd-to-flux-migration/), I audited the existing ArgoCD setup with their script (`audit-argocd.sh`, which lists Applications, AppProjects, ApplicationSets, Helm apps and repo credentials).

Also run `helm ls -A`. The **CHART** column gives the exact chart version to pin (for example `forgejo-17.1.2` means version `17.1.2`). Do not use the APP VERSION column.

### Install Flux

```
curl -s https://fluxcd.io/install.sh | sudo bash
flux check --pre
```

### Bootstrap

```
export GITHUB_TOKEN=<token>
flux bootstrap github --owner=mferrie --repository=Home-Lab --private=false --personal=true --path=k3s
```

Run from the top level of the repo. Notes:

- This bootstraps against **GitHub**, so Flux pulls from GitHub, not Codeberg (the ArgoCD apps pointed at Codeberg). Commits must reach the GitHub remote (`gh`, or via a mirror) before Flux sees them. Check with `flux get sources git`.
- With `--path=k3s`, bootstrap writes `gotk-components.yaml`, `gotk-sync.yaml` and a `kustomization.yaml` into `k3s/flux-system/`, and sets the sync path to `./k3s`. **That path is too broad**, see the first problem below.

### Narrow the bootstrap path (required)

In `k3s/flux-system/gotk-sync.yaml`, set:

```yaml
spec:
  path: ./k3s/flux-system
```

(`path` is relative to the repo root, with no `../`.) Then make sure `k3s/flux-system/kustomization.yaml` lists everything Flux should apply:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - grafana-kustomization.yaml
  - apps.yaml
```

Commit and push, then apply by hand once, since the broken Kustomization cannot apply its own fix:

```
flux reconcile source git flux-system
kubectl apply -f k3s/flux-system/gotk-sync.yaml
flux reconcile kustomization flux-system --with-source --timeout=5m
```

Do **not** re-run `flux bootstrap` with `--path=k3s/flux-system`. That nests everything in `k3s/flux-system/flux-system/`, and re-running bootstrap overwrites the sync path.

### Migration inventory

The tutorial's `migration-inventory` ConfigMap is optional and Flux never reads it, so I skipped it. The `suspend` flags in `apps.yaml` do the same job.

## Migration loop

### 1. Add a suspended Kustomization to `apps.yaml`

Use `---` between entries, and make sure each `name` appears only once.

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  namespace: flux-system
spec:
  interval: 10m
  timeout: 10m            # Helm apps; plain manifests can omit
  path: ./k3s/<app>       # e.g. ./k3s/lgtm/loki
  prune: true
  wait: true
  suspend: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

The Kustomization objects live in `flux-system`. The apps themselves stay in their own namespaces, because the resources keep the namespaces their manifests declare. Do not set `targetNamespace` for apps that already declare theirs.

### 2. Before touching the app

- Take a Longhorn snapshot of any volume (vaultwarden, joplin, nextcloud, immich, forgejo, and so on).
- Dry run: `kubectl apply --dry-run=server -R -f k3s/<app>/` for plain manifests, or `kubectl kustomize k3s/<app>` for Helm folders.

### 3. Delete the Argo app, non-cascading

In the UI, choose **Non-cascading** in the delete dialog. A cascading delete removes the running workloads and PVCs.

### 4. Clear leftover Argo field ownership

Needed for **Helm apps** (this is what made immich's upgrade fail with a field-ownership conflict). Optional for plain manifests, where leftover ownership is harmless unless Flux applies a different value.

Preview (read-only):

```fish
kubectl get deploy,sts,svc,pvc,cm,ingress,sa,sealedsecret -n <namespace> -o json --show-managed-fields \
  | jq -r '.items[] | select(any(.metadata.managedFields[]?; .manager=="argocd-controller")) | "\(.kind | ascii_downcase) \(.metadata.name)"'
```

Fix (fish syntax; adds a loop that patches each listed resource):

```fish
kubectl get deploy,sts,svc,pvc,cm,ingress,sa,sealedsecret -n <namespace> -o json --show-managed-fields \
  | jq -r '.items[] | select(any(.metadata.managedFields[]?; .manager=="argocd-controller")) | "\(.kind | ascii_downcase) \(.metadata.name)"' \
  | while read -l k n
      kubectl patch $k $n -n <namespace> --type=json \
        -p '[{"op":"replace","path":"/metadata/managedFields","value":[{}]}]'
    end
```

Notes:

- Only metadata is reset. Nothing restarts and no data is touched.
- Re-run the preview afterwards. No `argocd-controller` rows should remain. (No `kubectl-patch` row appears either; the list is simply emptied.)
- `lgtm` holds several apps. Add `-l app.kubernetes.io/instance=<app>` to the `kubectl get` line so only that app is cleared.
- Cluster-scoped objects (ClusterRole, ClusterRoleBinding) are not covered by `-n`. Check those separately for homepage.
- Do not patch Secrets generated by the Sealed Secrets controller.

### 5. Helm apps only: add `kustomization.yaml` and `helmrelease.yaml`

Without a `kustomization.yaml`, Flux auto-generates one and fails on `values.yaml` ("missing Resource metadata").

`k3s/<app>/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <namespace of the existing Helm release>   # lgtm for loki, tempo, prometheus
resources:
  - helmrelease.yaml
configMapGenerator:
  - name: <app>-values
    files:
      - values.yaml
generatorOptions:
  disableNameSuffixHash: true
```

`k3s/<app>/helmrelease.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <app>
spec:
  type: oci                  # OCI repos only; omit for normal https:// repos
  interval: 1h
  url: <oci://... or https://...>
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app>                # must equal the name in `helm ls`, or set spec.releaseName
spec:
  interval: 10m
  chart:
    spec:
      chart: <chart name>
      version: "<chart version from helm ls>"
      sourceRef:
        kind: HelmRepository
        name: <app>
  valuesFrom:
    - kind: ConfigMap
      name: <app>-values
  upgrade:
    remediation:
      retries: 3
```

Rules:

- The namespace must already exist (they all do). Add a `namespace.yaml` later if the repo should rebuild from scratch.
- Release name and namespace must match `helm ls -A`, otherwise Flux installs a second copy.
- If the app's folder also holds plain manifests (immich: `namespace.yaml`, `pg.yaml`, `pvc.yaml`), list them under `resources:` too.

Known Helm releases (from `helm ls -A`):

| Release | Namespace | Chart version | Chart repo |
|---|---|---|---|
| forgejo | forgejo | 17.1.2 | `oci://code.forgejo.org/forgejo-helm` |
| nextcloud | nextcloud | 9.2.0 | `https://nextcloud.github.io/helm/` (not OCI) |
| immich | immich | pin 0.13.1 (see Problems) | TODO |
| loki | lgtm | 17.4.9 | TODO |
| prometheus | lgtm | 29.17.0 | TODO |
| tempo | lgtm | 2.2.3 | TODO |

### 6. Un-suspend, for every app (Helm and plain)

Set `suspend: false` for the app **in `apps.yaml` in Git** (do not use `flux resume`; the bootstrap Kustomization would put it back), commit, push, then:

```
flux reconcile kustomization flux-system --with-source --timeout=5m
flux get kustomizations
flux get helmreleases -A      # Helm apps
```

If the CLI prints `context deadline exceeded`, it only gave up waiting. Check `flux get kustomizations` before assuming a failure.

### 7. Verify

- Pods keep their original ages (no restarts), PVCs stay Bound.
- Open the app and log in.
- Helm apps: `helm ls -n <ns>` shows a new revision, same chart version.

Leave `wait: true` on. It makes "Ready" mean the workloads are healthy. Only set `wait: false` temporarily while debugging a slow-starting app.

## Problems encountered

1. **`failed to decode ... k3s/forgejo/values.yaml: missing Resource metadata`.** Bootstrap used `--path=k3s`, so Flux scanned the whole tree. Fixed by narrowing the sync path (see Setup).
2. **`may not add resource with an already registered id ... forgejo`.** `apps.yaml` defined the forgejo Kustomization twice. Check with `grep -A2 "^kind: Kustomization" k3s/flux-system/apps.yaml | grep "name:" | sort | uniq -d` and `kubectl kustomize k3s/flux-system > /dev/null && echo OK`.
3. **Immich upgrade conflict.** Helm revision 2 (chart 0.13.2) failed with a conflict with `argocd-controller`. The live resources are still labeled chart 0.13.1, so Argo rendered 0.13.1 all along, with the image pinned to v3.3.5 in `values.yaml`. `kubectl diff` of 0.13.2 showed only label and tracking-annotation changes. Pin 0.13.1 for the migration and bump to 0.13.2 separately.
4. **homepage `secret.yaml` looks empty.** It is a `kubernetes.io/service-account-token` Secret; Kubernetes fills in the token. Keep it.

## Left alone for now

- `traefik`, `traefik-crd`: bundled with k3s, managed by its own helm controller.
- `sealed-secrets`, `longhorn`, `kube-state-metrics`: Helm releases with no folder in the repo. Add HelmReleases later. Do not remove sealed-secrets or your SealedSecrets stop decrypting.
- metallb, cert-manager, longhorn config folders need their controllers' CRDs. Migrate them last.

## Order for the remaining apps

searxng, mealie, vaultwarden, pihole-unbound (DNS, so be careful), loki, tempo, prometheus, nextcloud, immich, then the config-only folders.
