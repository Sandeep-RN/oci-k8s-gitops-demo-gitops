#!/usr/bin/env bash
# Seal the cert-manager Cloudflare API token into the gitops repo (demo #86).
#
# The token needs Zone:DNS:Edit and Zone:Zone:Read on the sandeeprn.in zone
# only. It is read from a hidden prompt, so it never reaches shell history or
# logs. It does touch disk briefly: a private (mode 600) temp file that kubectl
# reads, removed on exit.
#
# Sealing needs no cluster access: it uses this cluster's public certificate.
# Re-running replaces the SealedSecret (a fresh encryption each time) and does
# not duplicate the kustomization entry.
#
# Usage: scripts/seal-cloudflare-token.sh   (from anywhere in the repo)
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cert="${repo}/argocd/clusters/oke/sealed-secrets-cert.pem"
dir="${repo}/platform/cert-manager-issuers"
out="${dir}/cloudflare-api-token-sealedsecret.yaml"
kust="${dir}/kustomization.yaml"
entry="cloudflare-api-token-sealedsecret.yaml"

command -v kubeseal >/dev/null || { echo "kubeseal not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$cert" ] || { echo "missing $cert" >&2; exit 1; }

read -r -s -p "Cloudflare API token for cert-manager (hidden): " token
echo
[ -n "$token" ] || { echo "empty token" >&2; exit 1; }

# Temp files: the manifest is written aside so a failure never leaves a
# half-written one, and the token goes through a private file because
# kubectl cannot read it from stdin on Windows (/dev/stdin) and a
# --from-literal argument would show in the process list. Both are removed on
# exit, including on error.
umask 077
tmp=$(mktemp)
tokfile=$(mktemp)
trap 'rm -f "$tmp" "$tokfile"' EXIT
printf '%s' "$token" >"$tokfile"
unset token
# --scope strict binds the sealed value to this exact name and namespace.
kubectl create secret generic cloudflare-api-token -n cert-manager \
    --dry-run=client -o json --from-file=api-token="$tokfile" |
  kubeseal --cert "$cert" --format yaml --scope strict >"$tmp"
grep -q '^kind: SealedSecret' "$tmp" || { echo "output is not a SealedSecret" >&2; exit 1; }

# The EXIT trap still removes the token file ("$tmp" is gone after the move).
mv "$tmp" "$out"

# Idempotent: add the entry only when it is not there yet.
if ! grep -qx "  - ${entry}" "$kust"; then
  printf '  - %s\n' "$entry" >>"$kust"
fi
echo "Sealed -> ${out#"$repo"/}. Review the diff, then commit it."
