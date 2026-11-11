#!/usr/bin/env bash
# Seal the k3s node's public IP for Traefik (ADR 0022; demo #114).
#
# On k3s there is no load balancer: Traefik writes the node's public IP into
# every Ingress status (--providers.kubernetesingress.ingressendpoint.ip), and
# external-dns publishes it. Traefik reads the IP from the Secret
# traefik-public-ip (key public-ip) in kube-system. The IP is not a secret once
# DNS shows it; it is sealed because this repo is public and never holds IPs in
# plain text, and so the value lives in exactly one place.
#
# Run it again only if the node's public IP changes (the instance was
# terminated or its VNIC replaced). After the new file merges, k3s restarts
# Traefik with the new address and the DNS record follows by itself.
#
# The IP is never printed. It is read from K3S_NODE_IP, or from a hidden
# prompt. It does touch disk briefly: a private (mode 600) temp file that
# kubectl reads, removed on exit.
#
# Sealing needs no cluster access: it uses the cluster's public certificate.
# Re-running replaces the SealedSecret (a fresh encryption each time).
#
# Usage: scripts/seal-traefik-public-ip.sh            (from anywhere in the repo)
#        K3S_NODE_IP=$(terraform -chdir=<demo repo>/terraform/k3s output -raw public_ip) \
#          scripts/seal-traefik-public-ip.sh
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cert="${repo}/argocd/clusters/k3s/sealed-secrets-cert.pem"
out="${repo}/edge/traefik-k3s/public-ip-sealedsecret.yaml"

command -v kubeseal >/dev/null || { echo "kubeseal not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$cert" ] || { echo "missing $cert" >&2; exit 1; }

ip=${K3S_NODE_IP:-}
if [ -z "$ip" ]; then
  read -r -s -p "Public IP of the k3s node (hidden): " ip
  echo
fi
# Windows tools end their output with \r\n. Any stray whitespace would become
# part of Traefik's argument, so drop it before checking.
ip=$(printf '%s' "$ip" | tr -d '[:space:]')

# Errors below never echo the value.
[[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] ||
  { echo "not an IPv4 address (a.b.c.d)" >&2; exit 1; }
# 10# forces base 10: a leading zero would otherwise be read as octal.
a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
for octet in "$a" "$b" "$c" "$d"; do
  [ "$octet" -le 255 ] || { echo "not an IPv4 address (octet above 255)" >&2; exit 1; }
done
# The mistake this guards against: sealing the address the node itself shows
# (`ip addr`, the Service status), which is the private one (ADR 0022).
# external-dns would then publish nothing, and nothing would say why.
if [ "$a" -eq 10 ] || [ "$a" -eq 127 ] || [ "$a" -eq 0 ] || [ "$a" -ge 224 ] ||
  { [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; } ||
  { [ "$a" -eq 192 ] && [ "$b" -eq 168 ]; } ||
  { [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; } ||
  { [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; }; then
  echo "that is not a public address (private, loopback, link-local, shared or multicast range)." >&2
  echo "Use the node's PUBLIC IP: terraform -chdir=terraform/k3s output -raw public_ip (demo repo)." >&2
  exit 1
fi
# Canonical form, so "010.1.2.3" cannot reach Traefik.
ip="${a}.${b}.${c}.${d}"

# Temp files: the manifest is written aside so a failure never leaves a
# half-written one, and the value goes through a private file because kubectl
# cannot read it from stdin on Windows (/dev/stdin). Both are removed on exit,
# including on error.
umask 077
tmp=$(mktemp)
ipfile=$(mktemp)
trap 'rm -f "$tmp" "$ipfile"' EXIT
# No trailing newline: the file's bytes become the argument's value.
printf '%s' "$ip" >"$ipfile"
unset ip a b c d
# --scope strict binds the sealed value to this exact name and namespace.
kubectl create secret generic traefik-public-ip -n kube-system \
    --dry-run=client -o json --from-file=public-ip="$ipfile" |
  kubeseal --cert "$cert" --format yaml --scope strict >"$tmp"
grep -q '^kind: SealedSecret' "$tmp" || { echo "output is not a SealedSecret" >&2; exit 1; }

# The EXIT trap still removes the value file ("$tmp" is gone after the move).
mv "$tmp" "$out"
echo "Sealed -> ${out#"$repo"/}. Review the diff, then commit it."
