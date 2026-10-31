#!/usr/bin/env bash
# Seal a Cloudflare API token into the gitops repo (demo #86, #88; ADR 0020).
#
# Two components each have their own token (a leak or rotation affects one):
#   cert-manager   DNS-01 challenges   -> platform/cert-manager-issuers
#   external-dns   demo.sandeeprn.in   -> platform/external-dns
# Both are a Secret named cloudflare-api-token, key api-token, in the
# component's namespace.
#
# Each token needs Zone:DNS:Edit and Zone:Zone:Read on the sandeeprn.in zone
# only. It is read from a hidden prompt, so it never reaches shell history or
# logs. It does touch disk briefly: a private (mode 600) temp file that kubectl
# reads, removed on exit.
#
# Sealing needs no cluster access: it uses this cluster's public certificate.
# Re-running replaces the SealedSecret (a fresh encryption each time) and does
# not duplicate the kustomization entry.
#
# Usage: scripts/seal-cloudflare-token.sh cert-manager|external-dns
#        (from anywhere in the repo)
set -euo pipefail

# No default target: sealing a token into the wrong component would work
# silently and give that component the other's identity.
component=${1:-}
case "$component" in
  cert-manager) ns=cert-manager; dir_name=cert-manager-issuers ;;
  external-dns) ns=external-dns; dir_name=external-dns ;;
  *) echo "usage: $0 cert-manager|external-dns" >&2; exit 2 ;;
esac

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cert="${repo}/argocd/clusters/oke/sealed-secrets-cert.pem"
dir="${repo}/platform/${dir_name}"
out="${dir}/cloudflare-api-token-sealedsecret.yaml"
kust="${dir}/kustomization.yaml"
entry="cloudflare-api-token-sealedsecret.yaml"

command -v kubeseal >/dev/null || { echo "kubeseal not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$cert" ] || { echo "missing $cert" >&2; exit 1; }

read -r -s -p "Cloudflare API token for ${component} (hidden): " token
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
kubectl create secret generic cloudflare-api-token -n "$ns" \
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
