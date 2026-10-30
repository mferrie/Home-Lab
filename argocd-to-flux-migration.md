### ­ArgoCD to Flux Migration, 10/29/2026

## Rationale

I decided to switch my GitOps pipeline from ArgoCD to Flux because I had read that Flux was lighter in resources, and that the CLI-only pipeline was more efficient than the GUI.

## Process

# Installing Flux

Using [https://oneuptime.com/blog/post/2026-01-27-argocd-to-flux-migration/](https://oneuptime.com/blog/post/2026-01-27-argocd-to-flux-migration/) as a guide, I began the migration by conducting an audit using the script they recommended.

Code:

```
#!/bin/bash
# audit-argocd.sh
# Script to audit your current ArgoCD setup before migration

echo "=== ArgoCD Audit Report ==="
echo ""

# List all Applications
echo "## Applications"
kubectl get applications -n argocd -o custom-columns=\
NAME:.metadata.name,\
PROJECT:.spec.project,\
REPO:.spec.source.repoURL,\
PATH:.spec.source.path,\
SYNC:.status.sync.status

echo ""

# List all AppProjects
echo "## AppProjects"
kubectl get appprojects -n argocd -o custom-columns=\
NAME:.metadata.name,\
DESCRIPTION:.spec.description

echo ""

# List all ApplicationSets
echo "## ApplicationSets"
kubectl get applicationsets -n argocd -o custom-columns=\
NAME:.metadata.name,\
GENERATOR:.spec.generators[0]

echo ""

# Check for Helm-based applications
echo "## Helm Applications"
kubectl get applications -n argocd -o json | \
    jq -r '.items[] | select(.spec.source.chart != null) |
        "\(.metadata.name): \(.spec.source.chart) @ \(.spec.source.repoURL)"'

echo ""

# List repository credentials
echo "## Repository Credentials"
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository \
    -o custom-columns=NAME:.metadata.name,URL:.data.url

echo ""
echo "=== Audit Complete ==="
```

I then installed Flux on my system by running

```
curl -s https://fluxcd.io/install.sh | sudo bash
```

on my laptop.

After running the flux check for good measure, I then bootstrapped Flux with the following command:

```
flux bootstrap github --owner=mferrie --repository=Home-Lab --private=false --personal=true --path=k3s
```

from inside the top level of my repository.

The next step in the article was, as I found out through asking Claude, not strictly necessary and just for the developer's convenience (creating a migration inventory), so I skipped it.

# Actual Migration Loop

The rest of the process is ongoing as of 8 PM on 10/29, but essentially it is a loop of the following:

- In k3s/flux-system, add the apps as Kustomizations (I put it under k3s/flux-system/apps.yaml)

  - Format:

```
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
    name: <app>
    namespace: flux-system
spec:
    interval: 10m
    path: ./k3s/<app>
    prune: true
    wait: true
    suspend: true
    sourceRef:
        kind: GitRepository
        name: flux-system
```

- Delete the ArgoCD app from the UI (IMPORTANT: must be done in non-cascading mode!)

- Clear leftover ArgoCD app ownership metadata with the command:

```
| jq -r '.items[] | select(any(.metadata.managedFields[]?; .manager=="argocd-controller")) | "\(.kind | ascii_downcase) \(.metadata.name)"' \
| while read -l k n
  kubectl patch $k $n -n <app> --type=json \
    -p '[{"op":"replace","path":"/metadata/managedFields","value":[{}]}]'
end```
```

- In k3s, create a helmrelease.yaml and kustomization.yaml for apps that used Helm.

  - kustomization.yaml:

```
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app namespace>
resources:
    - helmrelease.yaml
configMapGenerator:
    - name: <app>>-values
        files:
            - values.yaml
generatorOptions:
    disableNameSuffixHash: true
```

- helmrelease.yaml:

```
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
    name: <app>
spec:
    type: oci
    interval: 1h
    url: (app OCI repository)
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
    name: <app>
spec:
    interval: 10m
    chart:
        spec:
            chart: <app>
                version: <app chart version>
    sourceRef:
        kind: HelmRepository
        name: <app>
        valuesFrom:
            - kind: ConfigMap
                name: <app>-values
```

- For apps that do not use Helm, but instead are raw manifests, run

```
   flux reconcile kustomization flux-system --with-source --timeout=5m
```

after setting suspend to false in apps.yaml and committing the change to the repository.

- Toggle "wait" to "false" in apps.yaml.

