#!/usr/bin/env bash
# Seal named link-creation tokens into the OKE overlay (demo #87, ADR 0020).
#
# One SealedSecret, link-tokens, holds every token: the key is the token's
# name (owner, k6), the value is the token. The backend mounts it as a
# directory, one file per token, and records the name with each link it
# creates. Values are never logged; names are.
#
# Each value is read from a hidden prompt. Generate it first and keep it in the
# password manager (`openssl rand -hex 32`), then paste it here. It never
# reaches shell history, argv, logs or Git in plaintext. It does touch disk
# briefly: one private (mode 600) temp file per token, which kubectl reads,
# removed on exit.
#
# Adding or rotating a token re-seals only the names given (kubeseal
# --merge-into); the other tokens are kept as they are. To revoke a token,
# delete its line under spec.encryptedData and merge the PR: the kubelet
# refreshes the mounted Secret within about a minute, with no restart.
#
# Sealing needs no cluster access: it uses this cluster's public certificate.
#
# Usage: scripts/seal-link-tokens.sh NAME [NAME...]   e.g. owner k6
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cert="${repo}/argocd/clusters/oke/sealed-secrets-cert.pem"
dir="${repo}/apps/link-shortener/overlays/oke"
entry="link-tokens-sealedsecret.yaml"
out="${dir}/${entry}"
kust="${dir}/kustomization.yaml"
# The backend ignores shorter values (app MIN_TOKEN_LENGTH); fail here instead.
min_length=32
# Same rule as the app's token names: they are logged and stored with links.
name_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'

[ $# -gt 0 ] || { echo "usage: $0 NAME [NAME...]   e.g. owner k6" >&2; exit 2; }
command -v kubeseal >/dev/null || { echo "kubeseal not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$cert" ] || { echo "missing $cert" >&2; exit 1; }

seen=" "
for name in "$@"; do
  [[ "$name" =~ $name_re ]] || { echo "invalid token name: $name" >&2; exit 2; }
  [[ "$seen" != *" ${name} "* ]] || { echo "token name given twice: $name" >&2; exit 2; }
  seen+="${name} "
done

# Private temp dir: one file per token, because kubectl cannot read a value
# from stdin on Windows (/dev/stdin) and --from-literal would show in the
# process list. The sealed result is also written here first, so a failure
# never leaves a half-written manifest. Removed on exit, including on error.
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/tokens"

from_files=()
for name in "$@"; do
  read -r -s -p "Value for link token '${name}' (hidden): " value
  echo >&2
  if [ "${#value}" -lt "$min_length" ]; then
    echo "token '${name}' is shorter than ${min_length} characters; the app would ignore it" >&2
    exit 1
  fi
  printf '%s' "$value" >"$tmp/tokens/$name"
  from_files+=(--from-file="${name}=${tmp}/tokens/${name}")
done
unset value

# --scope strict binds every value to this exact name and namespace.
# --merge-into replaces only the keys given and keeps the others.
sealed="$tmp/sealed.yaml"
if [ -f "$out" ]; then
  cp "$out" "$sealed"
  kubectl create secret generic link-tokens -n link-shortener \
      --dry-run=client -o json "${from_files[@]}" |
    kubeseal --cert "$cert" --format yaml --scope strict --merge-into "$sealed"
else
  kubectl create secret generic link-tokens -n link-shortener \
      --dry-run=client -o json "${from_files[@]}" |
    kubeseal --cert "$cert" --format yaml --scope strict >"$sealed"
fi
grep -q '^kind: SealedSecret' "$sealed" || { echo "output is not a SealedSecret" >&2; exit 1; }
for name in "$@"; do
  grep -q "^    ${name}: " "$sealed" || { echo "token '${name}' is missing from the output" >&2; exit 1; }
done

mv "$sealed" "$out"

# The overlay lists the file under resources. Not appended here: that file
# ends with patches, so a line added at the end would land in the wrong list.
grep -qx "  - ${entry}" "$kust" || echo "warning: ${entry} is not in ${kust#"$repo"/} resources" >&2
echo "Sealed $# token(s) -> ${out#"$repo"/}. Review the diff, then commit it."
