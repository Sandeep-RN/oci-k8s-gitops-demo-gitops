# oci-k8s-gitops-demo-gitops

Source of truth for the demo cluster. ArgoCD watches this repo and syncs it to
the single-node k3s cluster that serves `https://demo.sandeeprn.in`. The OKE
target served the site until 2026-11-12. It still exists with no public way in;
its teardown is issue [#13](https://github.com/Sandeep-RN/oci-k8s-gitops-demo/issues/13)
(due 2026-11-15). Once ArgoCD runs, **nothing is applied by hand with
kubectl**: change manifests here and let ArgoCD sync.

> **Status (2026-11-13):** k3s serves
> [demo.sandeeprn.in](https://demo.sandeeprn.in/) with 10 ArgoCD Applications
> (the root `root-k3s` and 9 children). It runs:
> - k3s's bundled Traefik on the node's public IP through ServiceLB with
>   `externalTrafficPolicy: Local`, so there is no load balancer (ADR 0022);
> - cert-manager with a Let's Encrypt production certificate, and external-dns;
> - Sealed Secrets;
> - the link shortener with PostgreSQL (sealed credentials, token-gated link
>   creation);
> - kube-prometheus-stack with the redirect SLO and burn-rate alerts to Discord;
> - the in-cluster redirect probe;
> - nightly database backups to Object Storage.
>
> Operating the edge:
> [edge runbook](https://github.com/Sandeep-RN/oci-k8s-gitops-demo/blob/main/docs/runbooks/edge.md).

Part of a three-repo project. The
[architecture document](https://github.com/Sandeep-RN/oci-k8s-gitops-demo/blob/main/docs/architecture.md),
ADRs and the issue tracker live in
[oci-k8s-gitops-demo](https://github.com/Sandeep-RN/oci-k8s-gitops-demo);
application code and CI live in
[oci-k8s-gitops-demo-app](https://github.com/Sandeep-RN/oci-k8s-gitops-demo-app).

## Layout

```
apps/<name>/base               Kustomize base: Deployment, Services, PDB, Postgres StatefulSet,
                               backup CronJob, ServiceMonitor, SLO rules, Grafana dashboard
apps/<name>/overlays/k3s       Live cluster (ADR 0022): the Ingress for demo.sandeeprn.in, the HSTS
                               and rate-limit middlewares (per client, 20/s burst 40) and the k3s
                               storage settings
apps/<name>/overlays/oke       Retired OKE target (ADR 0015): ClusterIP only, strict spread, no
                               Ingress since the DNS switch (2026-11-12)
argocd/install                 ArgoCD, pinned upstream install (ArgoCD manages itself from here)
argocd/clusters/<cluster>/     root.yaml (app of apps) + apps/ (AppProject, Applications)
edge/<component>/              Helm values for cert-manager, external-dns and (OKE only) Traefik
                               (ADR 0020); chart pinned in the cluster's Application
edge/traefik-k3s               A kustomization, unlike the other edge/ folders: a HelmChartConfig
                               for the chart k3s ships, the sealed public IP, a ServiceMonitor
platform/<addon>/              cluster add-ons and their sealed tokens (sealed-secrets,
                               cert-manager issuers, external-dns)
monitoring/kube-prometheus-stack/  Helm values (shared + per cluster); chart pinned in the cluster's monitoring app
monitoring/blackbox-exporter   Helm values for the blackbox exporter used by the redirect probe
monitoring/<cluster>/          objects the chart does not create (Grafana admin and Discord webhook SealedSecrets)
scripts/                       seal-link-tokens.sh, seal-cloudflare-token.sh and
                               seal-traefik-public-ip.sh (sealing needs no cluster access)
tests/prometheus/              promtool unit tests for the alert rules (run in CI)
.github/workflows/             validate (kubeconform, Helm render, promtool, amtool), gitleaks
```

`monitoring/<cluster>/` exists for `k3s` and `oke`. `edge/traefik` holds the
upstream Traefik chart values that only OKE used.

## Bootstrap a cluster (the only manual kubectl, once per cluster)

Restore the Sealed Secrets keys **first**: a controller that starts without
them makes a new key, and no sealed file in this repo would decrypt (ADR 0022).
Then:

```
kubectl apply --server-side -k argocd/install
kubectl apply -f argocd/clusters/k3s/root.yaml
```

The live root is `argocd/clusters/k3s/root.yaml`
(`argocd/clusters/oke/root.yaml` is the retired OKE root). The full steps, as
they were run on 2026-11-12, are in the
[k3s bootstrap runbook](https://github.com/Sandeep-RN/oci-k8s-gitops-demo/blob/main/docs/runbooks/k3s-bootstrap.md).

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
the overlay, mounted into the backend as one file per token. The live copy is
`apps/link-shortener/overlays/k3s/link-tokens-sealedsecret.yaml`. Add or rotate
with `scripts/seal-link-tokens.sh NAME...` (hidden prompt; values live in the
password manager); revoke by deleting the key (see the script header). Anything
that creates links (the demo repo's verify script) reads its token from the
`LINK_TOKEN` environment variable, never from a repo. A k6 load job is not built.

**Known gap:** `scripts/seal-link-tokens.sh` still writes to `overlays/oke`.
Until it points at `overlays/k3s` (tracked in issue
[#13](https://github.com/Sandeep-RN/oci-k8s-gitops-demo/issues/13) of the demo
repo), using it changes only the OKE copy, so a revoked token would keep working
on the live site.

**Cloudflare tokens** (ADR 0020): cert-manager and external-dns each have
their own token (Zone:DNS:Edit and Zone:Zone:Read on `sandeeprn.in` only).
Seal or rotate with `scripts/seal-cloudflare-token.sh cert-manager` or
`scripts/seal-cloudflare-token.sh external-dns` (hidden prompt).

**external-dns** owns `demo.sandeeprn.in` through a TXT record (owner id
`oci-demo-k3s` on k3s, set in `edge/external-dns/values-k3s.yaml`; it was
`oci-demo-oke` on OKE; prefix `edns-`). Never change either on a running
cluster: the existing records would be orphaned. The OKE Ingress was removed by
PR #59 on 2026-11-12, so the DNS records now belong to k3s. Do not delete them
during the OKE teardown.

## Working here

- Install hooks once: `pip install pre-commit && pre-commit install`
  (gitleaks with custom OCI rules). CI also scans the full history with
  gitleaks, since `--no-verify` skips hooks. SealedSecret ciphertext is
  allowlisted narrowly in `.gitleaks.toml`.
- **This repo is public.** Never commit tokens, passwords, kubeconfig, OCIDs
  or public IPs.
