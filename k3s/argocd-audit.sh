#!/bin/bash

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
