# OKE cluster

- `root.yaml`: the app-of-apps root, applied once at bootstrap.
- `apps/`: what ArgoCD runs on this cluster.
- `sealed-secrets-cert.pem`: this cluster's Sealed Secrets **public** certificate.
  It can only encrypt, so it is safe to commit. Seal without cluster access:

  ```
  kubectl create secret generic NAME -n NAMESPACE --dry-run=client -o json --from-literal=key=value \
    | kubeseal --cert argocd/clusters/oke/sealed-secrets-cert.pem --format yaml --scope strict
  ```

  Prefer piping generated values straight in (as done for `postgres-credentials`)
  so plaintext never lands in shell history. The controller renews its key every
  30 days; old SealedSecrets keep working, and new ones should use a freshly
  fetched cert (`kubeseal --fetch-cert`). Backup and restore of the private keys:
  oci-k8s-gitops-demo `docs/runbooks/sealed-secrets.md`.
