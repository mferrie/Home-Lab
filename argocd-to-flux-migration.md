# ArgoCD to Flux Migration

**Started:** 2026-10-29\
**Last updated:** 2026-10-30

## Goal and rationale

Migrate the homelab's GitOps management from ArgoCD to Flux while
keeping existing workloads and persistent data running.

The workflow is intentionally conservative:

-   Keep existing Kubernetes resources in place wherever possible.
-   Remove ArgoCD ownership without cascading deletion of workloads or
    PVCs.
-   Add Flux Kustomizations that point to the existing application
    directories.
-   Reconcile one application at a time and verify it before moving on.
-   Preserve existing PVCs and application data.
-   Keep the desired state in Git. Change `apps.yaml` rather than using
    one-off `flux resume` commands for routine enablement.

Flux is operated through the `flux` CLI, `kubectl`, and Git; it does not
include a built-in graphical UI.

## Current migration status

Snapshot from `flux get kustomizations -A` on 2026-10-30. "Ready" means
the Flux Kustomization has successfully applied its configured path; it
does not by itself prove every application feature has been tested.

  ---------------------------------------------------------------------------------
  Kustomization / app     Workload type     Flux state        Notes
  ----------------------- ----------------- ----------------- ---------------------
  `flux-system`           Flux bootstrap    Ready             Syncs
                                                              `./k3s/flux-system`

  `forgejo`               Helm              Ready             Migrated

  `homepage`              Raw manifests     Ready             Migrated

  `grafana`               Raw manifests     Ready             Migrated; existing
                                                              PVC retained

  `joplin`                Raw manifests     Ready             Migrated

  `searxng`               Raw manifests     Ready             Migrated

  `loki`                  Helm              Ready             Migrated

  `prometheus`            Helm              Ready             Migrated; chart
                                                              `29.40.0`

  `mealie`                Raw manifests     Suspended, Ready  Previously applied;
                                                              currently
                                                              intentionally
                                                              suspended

  `vaultwarden`           Raw manifests     Suspended         Pending /
                                                              intentionally
                                                              suspended

  `pihole-unbound`        Raw manifests     Suspended         Pending; DNS service,
                                                              migrate carefully

  `tempo`                 Helm              Suspended         Pending

  `nextcloud`             Helm              Suspended         Pending

  `immich`                Helm + raw        Suspended         Pending; do after
                          manifests                           simpler applications

  `metallb-config`        Configuration     Suspended         Do after the
                          manifests                           controller/CRDs are
                                                              available

  `cert-manager-config`   Configuration     Suspended         Do after the
                          manifests                           controller/CRDs are
                                                              available

  `longhorn-config`       Configuration     Suspended         Do after the
                          manifests                           controller/CRDs are
                                                              available
  ---------------------------------------------------------------------------------

Other Kustomizations such as `metallb-config`, `cert-manager-config`,
`longhorn-config`, `nextcloud`, `immich`, `tempo`, and `vaultwarden`
were shown as suspended and waiting to be reconciled in that status
snapshot.

Check live state rather than relying on this table after further
changes:

``` bash
flux get kustomizations -A
flux get helmreleases -A
flux get sources all -A
```

## Repository and Flux layout

Flux is bootstrapped from GitHub, not directly from the Codeberg remote
previously used by ArgoCD. Commits must reach the GitHub repository
(directly or through the configured mirror) before Flux can see them.

The bootstrap sync path is deliberately narrow:

``` yaml
spec:
  path: ./k3s/flux-system
```

The Flux system Kustomize root includes the bootstrap resources and the
application Kustomization definitions, for example:

``` yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - apps.yaml
```

The `apps.yaml` file defines one Flux `Kustomization` object per
application. Each object points to that application's directory in the
repository.

Do not broaden the bootstrap path to `./k3s`: application directories
can contain Helm `values.yaml` files, which are not Kubernetes
manifests. Flux/Kustomize will try to parse them as resources and fail
with errors such as `missing Resource metadata`.

## The migration workflow

### 1. Audit the existing application

Before changing ownership, establish what is actually running and how it
is installed.

Useful commands:

``` bash
helm ls -A
kubectl get deploy,sts,ds,svc,ingress,pvc -A
kubectl get kustomizations -A
```

For the target application, inspect its namespace and resources:

``` bash
kubectl get all,pvc,cm,secret,ingress -n <namespace>
```

Record:

-   Whether the app is a Helm release or raw Kubernetes manifests.
-   The current Helm release name, namespace, chart name, and chart
    version, if applicable.
-   Existing PVC names, storage classes, access modes, and bound PVs.
-   Current image versions, environment variables, probes, resources,
    service, and ingress settings.
-   Whether configuration is stored in Git, ConfigMaps/Secrets, or the
    application's persistent data.

For Helm, use the **CHART** column from `helm ls -A` to identify the
chart version to pin. Do not use the APP VERSION column as the chart
version.

### 2. Back up persistent data

Before migrating an application with persistent storage, take a Longhorn
snapshot or another application-appropriate backup.

Do not delete or recreate PVCs as part of a GitOps ownership migration.
Keep the existing claim name and storage configuration unless there is a
separate, deliberate storage migration.

For Grafana, `/var/lib/grafana` is mounted from `grafana-pvc`. That PVC
was already Bound when Flux was enabled, and the raw manifest retained
the same claim name.

### 3. Put the application's desired state in its repository directory

Each application has its own path, such as:

-   `./k3s/forgejo`
-   `./k3s/lgtm/loki`
-   `./k3s/lgtm/prometheus`
-   `./k3s/lgtm/grafana`

#### Raw-manifest applications

Keep the Kubernetes YAML files as raw manifests. Add a Kustomize file
that explicitly lists them.

Example `kustomization.yaml`:

``` yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana.yaml
```

The referenced manifest can contain a PVC, Deployment, Service, and
Ingress. No HelmRelease or Helm repository is needed for a raw-manifest
application.

Validate it before enabling reconciliation:

``` bash
kubectl kustomize k3s/<app>
```

#### Helm applications

A Helm application needs Flux source and HelmRelease resources, plus a
Kustomize root that includes them and any values ConfigMap or other raw
resources.

The exact source type depends on the chart repository:

-   Use `HelmRepository` for a conventional Helm repository.
-   Use `OCIRepository` for an OCI chart source.

Do not assume all charts use the same source kind. Pin the chart version
that matches the existing release so the first Flux reconciliation
adopts the existing release rather than unexpectedly upgrading it.

If values are stored in `values.yaml`, use a `configMapGenerator` or
another explicit Flux-supported values source and reference it from the
HelmRelease's `valuesFrom`. Make sure the Kustomize root does not try to
interpret `values.yaml` as a Kubernetes resource.

For apps that combine Helm with raw manifests, include both in the same
Kustomize root.

### 4. Define the Flux Kustomization in `apps.yaml`

Add one entry per application, initially suspended:

``` yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  namespace: flux-system
spec:
  interval: 10m
  timeout: 10m
  path: ./k3s/<app>
  prune: true
  wait: true
  suspend: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

Use the actual repository path. For example, the LGTM applications live
under `./k3s/lgtm/<app>`.

The Flux Kustomization object lives in `flux-system`; the application
resources remain in their declared namespaces. Do not add
`targetNamespace` when the manifests already specify their namespaces.

Check that each Kustomization name appears only once:

``` bash
grep -A2 '^kind: Kustomization' k3s/flux-system/apps.yaml \
  | grep 'name:' | sort | uniq -d
```

Validate the Flux system Kustomize root:

``` bash
kubectl kustomize k3s/flux-system >/dev/null && echo OK
```

### 5. Remove ArgoCD ownership without deleting workloads

Delete the ArgoCD Application using **Non-cascading** deletion. A
cascading deletion can remove the workloads and persistent volume claims
that must remain running.

For Helm applications, check whether live resources still have field
ownership recorded under `argocd-controller`. An ownership conflict
caused one Helm upgrade to fail during this migration.

Read-only inspection example:

``` fish
kubectl get deploy,sts,svc,pvc,cm,ingress,sa,sealedsecret \
  -n <namespace> -o json --show-managed-fields \
  | jq -r '.items[]
    | select(any(.metadata.managedFields[]?; .manager=="argocd-controller"))
    | "\(.kind | ascii_downcase) \(.metadata.name)"'
```

Only if a real conflict requires it, plan a targeted ownership cleanup.
Do not blindly patch every resource in a namespace: namespaces such as
`lgtm` contain multiple applications. Scope any operation to the
application being migrated.

Do not patch Secrets generated by the Sealed Secrets controller.
Cluster-scoped resources also need separate consideration because they
are not included by a namespaced query.

### 6. Enable the Flux Kustomization in Git

Change the application's `suspend` value in `apps.yaml` from `true` to
`false`, then commit and push.

This is the normal, Git-managed way to enable an application. A one-off
`flux resume` command can be useful operationally, but if Git still says
`suspend: true`, the parent Flux Kustomization can reapply that setting
later.

Reconcile the parent so it applies the updated `apps.yaml`:

``` bash
flux reconcile kustomization flux-system --with-source --timeout=5m
```

Then check the application:

``` bash
flux get kustomizations -A
flux get helmreleases -A
```

If the CLI reports `context deadline exceeded`, check the actual
Kustomization status before assuming the apply failed. The CLI may have
timed out waiting even though reconciliation later completed.

### 7. Verify the application

After reconciliation, verify:

-   The Flux Kustomization reports `Ready=True`.
-   The expected Pods are Running and Ready.
-   Existing PVCs remain Bound and retain their original names.
-   The application is reachable through its normal Service or Ingress.
-   The application can access its existing data.
-   For Helm apps, the HelmRelease is Ready and the release/chart
    version is what was intended.

Useful checks:

``` bash
flux get kustomizations -A
flux get helmreleases -A
kubectl get pods,pvc,svc,ingress -n <namespace>
```

For a no-disruption adoption, compare Pod ages before and after
reconciliation. A successful no-op adoption should not require a
rollout.

Keep `wait: true` for normal operation so a Kustomization is not
reported Ready before its resources are healthy. Change it only as a
deliberate troubleshooting measure.

## Lessons from this migration

### Bootstrap path must not include application folders

The initial bootstrap path was too broad. Flux attempted to parse
application `values.yaml` files as Kubernetes manifests and failed with
`missing Resource metadata`. Narrowing the sync path to
`./k3s/flux-system` fixed that.

### Avoid duplicate Kustomization definitions

A duplicated app entry in `apps.yaml` caused a Kustomize error about an
already registered resource ID. Check names for duplicates and validate
the root before pushing.

### Pin existing Helm chart versions during adoption

An Immich upgrade attempted to change chart version during migration and
hit an ArgoCD field-ownership conflict. The safe approach is to pin the
chart version that matches the live release for the adoption, then
perform a chart upgrade as a separate change.

### Preserve generated Kubernetes resources

A Homepage service-account-token Secret looked empty in its manifest,
but Kubernetes populates it. Do not remove such resources just because
their data is not written out in Git.

### Helm values need schema validation

During the Prometheus migration, the values file had `server.podLabels`
set to an array (`[]`) where the chart schema expected an object. It
needed to be `{}`.

The Prometheus Helm upgrade also initially failed because
`.Values.networkPolicy.enabled` was nil. The values file needed the
parent mapping:

``` yaml
networkPolicy:
  enabled: false
```

The actual Prometheus migration then required Flux to reconcile the
updated source values. The running Deployment had retained old settings
until the Helm upgrade succeeded. The final chart version in use is
`29.40.0`.

The Prometheus workload also had an OOM issue with a 512Mi memory limit.
The configured limit was raised to 1Gi. The existing TSDB PVC and data
were preserved.

### Raw manifests do not need to become Helm releases

Grafana is a raw-manifest deployment. Its migration required a
`kustomization.yaml` that references `grafana.yaml`, then enabling the
existing Flux Kustomization. It did not require a HelmRelease or chart
conversion.

The existing `grafana-pvc` was Bound and remained part of the manifest.
Flux reconciliation completed quickly because the live resources already
matched the desired manifests; no replacement deployment was needed.

## Applications and controllers intentionally left for later

-   `traefik` and `traefik-crd`: bundled with k3s and managed through
    its own Helm controller.
-   `sealed-secrets`, `longhorn`, and `kube-state-metrics`: Helm
    releases that did not yet have application folders in the
    repository. Add Flux definitions later if they are to be brought
    under this GitOps setup. Do not remove Sealed Secrets; doing so
    would prevent SealedSecrets from being decrypted.
-   MetalLB, cert-manager, and Longhorn configuration folders depend on
    their controllers and CRDs. Migrate their configuration only after
    confirming those controllers and CRDs are available.

## Suggested order for remaining work

Continue one application at a time, prioritizing simpler workloads
before critical or complex services:

1.  Vaultwarden
2.  Pi-hole / Unbound (DNS; schedule carefully)
3.  Tempo
4.  Nextcloud
5.  Immich
6.  MetalLB, cert-manager, and Longhorn configuration

Mealie is currently suspended despite having previously reached Ready,
so decide whether it should remain paused or be resumed as a separate
Git change.

Before each migration, re-check the live cluster and this document's
status table. The cluster state and Git state are authoritative; this
document is a working record, not a substitute for checking them.
