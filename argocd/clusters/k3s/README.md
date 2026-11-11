# k3s cluster

The single Always Free node (ADR 0001, 0022). Bootstrap order, the key restore
and the DNS switch: oci-k8s-gitops-demo `docs/runbooks/k3s-bootstrap.md`.

- `root.yaml`: the app-of-apps root, applied once at bootstrap, **after** the
  Sealed Secrets keys are restored.
- `apps/`: what ArgoCD runs on this cluster.
- `sealed-secrets-cert.pem`: the Sealed Secrets **public** certificate. It can
  only encrypt, so it is safe to commit. It is a copy of
  `../oke/sealed-secrets-cert.pem`: this cluster runs on the OKE sealing keys,
  restored from the offline backup (ADR 0022), so every sealed file in this
  repo decrypts on both clusters without resealing.

## What differs from OKE

| | OKE | k3s |
|---|---|---|
| Traefik | upstream chart, `apps/traefik.yaml` | the chart k3s ships, configured by `apps/traefik-config.yaml` (`edge/traefik-k3s`) |
| Way in | Network Load Balancer | the node's public IP through k3s's ServiceLB, no load balancer |
| Client IPs at Traefik | the load balancer's address | real (`externalTrafficPolicy: Local`) |
| Address in DNS | from the Service status | the node's public IP from a SealedSecret (`scripts/seal-traefik-public-ip.sh`) |
| external-dns owner id | `oci-demo-oke` | `oci-demo-k3s` |

`apps/traefik-config.yaml` shows Synced and Healthy as soon as its objects are
applied. That does not prove k3s accepted the values. Check the Helm job and
the result:

```
kubectl -n kube-system get pods -l helmcharts.helm.cattle.io/chart=traefik
kubectl -n kube-system get svc traefik -o jsonpath='{.spec.externalTrafficPolicy}'   # Local
kubectl get ingress -A                                                                # ADDRESS = the public IP
```

Sealing works as on OKE, with this folder's certificate:

```
kubectl create secret generic NAME -n NAMESPACE --dry-run=client -o json --from-literal=key=value \
  | kubeseal --cert argocd/clusters/k3s/sealed-secrets-cert.pem --format yaml --scope strict
```

The controller renews its key every 30 days; old SealedSecrets keep working,
and new ones should use a freshly fetched cert (`kubeseal --fetch-cert`).
Backup and restore of the private keys: oci-k8s-gitops-demo
`docs/runbooks/sealed-secrets.md`.
