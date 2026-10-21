# oci-k8s-gitops-demo-gitops

Source of truth for the demo cluster. ArgoCD watches this repo and syncs it to
a single-node k3s cluster on OCI Always Free. Once ArgoCD runs, **nothing is
applied by hand with kubectl**: change manifests here and let ArgoCD sync.

> **Status:** scaffolding only. Manifests and ArgoCD Applications arrive in
> Phase 2a.

Part of a three-repo project. Architecture, ADRs and the issue tracker live in
[oci-k8s-gitops-demo](https://github.com/Sandeep-RN/oci-k8s-gitops-demo);
application code and CI live in
[oci-k8s-gitops-demo-app](https://github.com/Sandeep-RN/oci-k8s-gitops-demo-app).

## Layout

```
apps/<name>/base         Kustomize base (Deployment, Service, ConfigMap, SealedSecret)
apps/<name>/overlays/prod  Environment overlay
argocd/                  ArgoCD bootstrap and app-of-apps
monitoring/              Prometheus / Grafana configuration
```

## How changes flow

1. The app repo's CI builds an image and opens a tag-bump PR here (ADR 0009).
   Do not edit those image tags by hand.
2. The PR merges (CI must pass, ADR 0011).
3. ArgoCD detects the change and syncs the cluster.

## Secrets

Only **SealedSecret** manifests may be committed, never plain Secrets (ADR
0006). Sealing keys are backed up outside this repo.

## Working here

- Install hooks once: `pip install pre-commit && pre-commit install`
  (gitleaks with custom OCI rules).
- **This repo is public.** Never commit tokens, passwords, kubeconfig, OCIDs
  or public IPs.
