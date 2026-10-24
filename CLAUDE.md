# oci-k8s-gitops-demo-gitops (Kubernetes manifests + ArgoCD)

Workspace-level rules and PLAN.md live one folder up. Read them first.

- This repo is the source of truth for the cluster. Never `kubectl apply` by
  hand once ArgoCD is running; change manifests here and let ArgoCD sync.
- Layout: apps/<name>/base + overlays/k3s and overlays/oke (Kustomize; ADR 0015), argocd/ for bootstrap
  and app-of-apps, monitoring/ for Prometheus/Grafana config.
- Secrets: only SealedSecret manifests may be committed, never plain Secrets.
- CI in the app repo bumps image tags here; do not edit those tags by hand.

## Agent skills

### Issue tracker

Issues for all three repos live in GitHub Issues on Sandeep-RN/oci-k8s-gitops-demo; pass `-R Sandeep-RN/oci-k8s-gitops-demo` to `gh issue` commands. See that repo's `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md` in the demo repo.

### Domain docs

Single-context, kept in the demo repo: one GLOSSARY.md and docs/adr/ at its root (this repo has none). See `docs/agents/domain.md` in the demo repo.
