# oci-k8s-gitops-demo-gitops

Source of truth for the demo cluster. ArgoCD watches this repo and syncs it to
a single-node k3s cluster on OCI Always Free. Once ArgoCD runs, **nothing is
applied by hand with kubectl**: change manifests here and let ArgoCD sync.

> **Status:** link-shortener base, k3s and OKE overlays, ArgoCD bootstrap for
> the OKE target. Ingress, Postgres and the k3s cluster root come next.

Part of a three-repo project. Architecture, ADRs and the issue tracker live in
[oci-k8s-gitops-demo](https://github.com/Sandeep-RN/oci-k8s-gitops-demo);
application code and CI live in
[oci-k8s-gitops-demo-app](https://github.com/Sandeep-RN/oci-k8s-gitops-demo-app).

## Layout

```
apps/<name>/base               Kustomize base (Deployment, Service, PDB)
apps/<name>/overlays/k3s       Always Free k3s node
apps/<name>/overlays/oke       Short-lived OKE target (ADR 0015): Flexible LB, strict spread
argocd/install                 ArgoCD, pinned upstream install (ArgoCD manages itself from here)
argocd/clusters/<cluster>/     root.yaml (app of apps) + apps/ (AppProject, Applications)
platform/<addon>/              cluster add-ons shared by all clusters (sealed-secrets, pinned)
monitoring/                    Prometheus / Grafana configuration
```

## Bootstrap a cluster (the only manual kubectl, once per cluster)

```
kubectl apply --server-side -k argocd/install
kubectl apply -f argocd/clusters/oke/root.yaml
```

After that, every change, including ArgoCD upgrades, is a PR to this repo.
`--server-side` is required because ArgoCD's CRDs are too large for
client-side apply. The ArgoCD UI is reached only by `kubectl port-forward`
(ADR 0014).

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
