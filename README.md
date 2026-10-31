# oci-k8s-gitops-demo-gitops

Source of truth for the demo clusters. ArgoCD watches this repo and syncs it:
today to the short-lived OKE target (ADR 0015), later to a single-node k3s
cluster on OCI Always Free. Once ArgoCD runs, **nothing is applied by hand
with kubectl**: change manifests here and let ArgoCD sync.

> **Status (2026-11-01):** running on OKE and served at
> [demo.sandeeprn.in](https://demo.sandeeprn.in/docs) (API page): Traefik behind the free NLB, cert-manager
> (Let's Encrypt production) and external-dns, the link shortener and
> PostgreSQL (sealed credentials, token-gated link creation, nightly backups to
> Object Storage), Sealed Secrets, and kube-prometheus-stack with the redirect
> SLO rules, burn-rate alerts to Discord and a Grafana dashboard. Next: the
> k3s cluster root, once the Always Free node exists. Operating the edge:
> [edge runbook](https://github.com/Sandeep-RN/oci-k8s-gitops-demo/blob/main/docs/runbooks/edge.md).

Part of a three-repo project. Architecture, ADRs and the issue tracker live in
[oci-k8s-gitops-demo](https://github.com/Sandeep-RN/oci-k8s-gitops-demo);
application code and CI live in
[oci-k8s-gitops-demo-app](https://github.com/Sandeep-RN/oci-k8s-gitops-demo-app).

## Layout

```
apps/<name>/base               Kustomize base: Deployment, Services, PDB, Postgres StatefulSet,
                               backup CronJob, ServiceMonitor, SLO rules, Grafana dashboard
apps/<name>/overlays/k3s       Always Free k3s node
apps/<name>/overlays/oke       Short-lived OKE target (ADR 0015): ClusterIP only, strict spread,
                               Ingress for demo.sandeeprn.in with a rate limit (ADR 0020)
argocd/install                 ArgoCD, pinned upstream install (ArgoCD manages itself from here)
argocd/clusters/<cluster>/     root.yaml (app of apps) + apps/ (AppProject, Applications)
edge/<component>/              Helm values for Traefik, cert-manager, external-dns (ADR 0020);
                               chart pinned in the cluster's Application
platform/<addon>/              cluster add-ons and their sealed tokens (sealed-secrets,
                               cert-manager issuers, external-dns)
monitoring/kube-prometheus-stack/  Helm values (shared + per cluster); chart pinned in the cluster's monitoring app
monitoring/<cluster>/          objects the chart does not create (Grafana admin and Discord webhook SealedSecrets)
tests/prometheus/              promtool unit tests for the alert rules (run in CI)
.github/workflows/             validate (kubeconform, Helm render, promtool, amtool), gitleaks
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
2. The PR merges once the required `validate` check passes (ADR 0011).
   `validate` renders every overlay and the pinned Helm chart and checks them
   with kubeconform, unit-tests the alert rules with promtool, and checks the
   Alertmanager config and routing with amtool.
3. ArgoCD detects the change and syncs the cluster.

## Secrets

Only **SealedSecret** manifests may be committed, never plain Secrets (ADR
0006). Sealing keys are backed up outside this repo.

**Link-creation tokens** (ADR 0020): creating a link needs a named token;
redirects do not. All tokens are keys of one SealedSecret, `link-tokens` in
the OKE overlay, mounted into the backend as one file per token. Add or rotate
with `scripts/seal-link-tokens.sh NAME...` (hidden prompt; values live in the
password manager); revoke by deleting the key (see the script header). Anything
that creates links (the demo repo's verify script, a future k6 job) reads its
token from the `LINK_TOKEN` environment variable, never from a repo.

**Cloudflare tokens** (ADR 0020): cert-manager and external-dns each have
their own token (Zone:DNS:Edit and Zone:Zone:Read on `sandeeprn.in` only).
Seal or rotate with `scripts/seal-cloudflare-token.sh cert-manager` or
`scripts/seal-cloudflare-token.sh external-dns` (hidden prompt).

**external-dns** owns `demo.sandeeprn.in` through a TXT record (owner id
`oci-demo-oke`, prefix `edns-`). Never change either on a running cluster:
the existing records would be orphaned. Before tearing the cluster down,
delete the Ingress first so external-dns removes the record.

## Working here

- Install hooks once: `pip install pre-commit && pre-commit install`
  (gitleaks with custom OCI rules). CI also scans the full history with
  gitleaks, since `--no-verify` skips hooks. SealedSecret ciphertext is
  allowlisted narrowly in `.gitleaks.toml`.
- **This repo is public.** Never commit tokens, passwords, kubeconfig, OCIDs
  or public IPs.
