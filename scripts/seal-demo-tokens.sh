#!/usr/bin/env bash
# Seal named demo tokens for the on-call assistant into its k3s overlay (demo
# #207, ADR 0003, ADR 0025; app issue #6).
#
# A demo token lifts the PUBLIC share of the assistant's daily LLM budget for
# its holder (the owner, a reviewer). It is a credential, so the cluster never
# holds it: this script reads the token, computes its SHA-256 here, and seals
# ONLY THE HASH. The app hashes the token a visitor sends and compares the two
# (constant time). Contract with the app: the stored value is the lowercase hex
# SHA-256 of the token's exact bytes, no newline; the app ignores surrounding
# whitespace.
#
# One SealedSecret, demo-tokens, holds every token: the key is the token's name
# (owner, reviewer-anna), the value is the hash. The app mounts it as a
# directory, one file per token, and logs the NAME with each question, never the
# token. A 256-bit random token cannot be guessed from its hash, so a plain
# SHA-256 is enough (a slow password hash only helps against human-chosen
# secrets).
#
# Each token is read from a hidden prompt. Generate it first and keep it in the
# password manager (`openssl rand -hex 32`), then paste it here; give the same
# value to the person who needs it. The token itself never reaches shell
# history, argv, logs, Git or disk: only its hash is written, to a private
# (mode 600) temp file that kubectl reads and that is removed on exit.
#
# Adding or rotating a token re-seals only the names given (kubeseal
# --merge-into); the other tokens are kept as they are. To REVOKE a token,
# delete its line under spec.encryptedData and merge the PR. Measured on the live
# cluster (demo #218, 2026-11-23, four merges): ArgoCD synced 1 to 5 minutes after
# the merge (61 to 302 s; it polls the repo), then the kubelet refreshed the
# mounted Secret within about a minute of the sync (3 to 16 s), with no restart.
#
# Sealing needs no cluster access: it uses this cluster's public certificate.
#
# Usage: scripts/seal-demo-tokens.sh NAME [NAME...]   e.g. owner reviewer-anna
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cert="${repo}/argocd/clusters/k3s/sealed-secrets-cert.pem"
dir="${repo}/apps/oncall-assistant/overlays/k3s"
entry="demo-tokens-sealedsecret.yaml"
out="${dir}/${entry}"
kust="${dir}/kustomization.yaml"
ns=oncall-assistant
# A shorter value is guessable; the app's own checks assume at least this much.
min_length=32
# Lowercase and short: the name is logged with every question and is a file name.
name_re='^[a-z0-9][a-z0-9-]{0,30}$'

[ $# -gt 0 ] || { echo "usage: $0 NAME [NAME...]   e.g. owner reviewer-anna" >&2; exit 2; }
command -v kubeseal >/dev/null || { echo "kubeseal not found" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
[ -f "$cert" ] || { echo "missing $cert" >&2; exit 1; }

# sha256sum on Linux and Git Bash, shasum on macOS.
if command -v sha256sum >/dev/null; then
  hash_stdin() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null; then
  hash_stdin() { shasum -a 256 | cut -d' ' -f1; }
else
  echo "neither sha256sum nor shasum found" >&2
  exit 1
fi

seen=" "
for name in "$@"; do
  [[ "$name" =~ $name_re ]] || { echo "invalid token name '${name}': lowercase letters, digits and '-', 1 to 31 characters" >&2; exit 2; }
  [[ "$seen" != *" ${name} "* ]] || { echo "token name given twice: $name" >&2; exit 2; }
  seen+="${name} "
done

# Private temp dir for the hashes and for the sealed result, which is written
# here first so a failure never leaves a half-written manifest.
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/hashes"

from_files=()
hashes=" "
for name in "$@"; do
  read -r -s -p "Value for demo token '${name}' (hidden): " value
  echo >&2
  # A paste from Windows can carry a CR; drop it so the hash is of what the
  # person will actually send.
  value=${value%$'\r'}
  if [[ "$value" =~ [[:space:]] ]]; then
    echo "token '${name}' contains whitespace; paste the value only" >&2
    exit 1
  fi
  if [ "${#value}" -lt "$min_length" ]; then
    echo "token '${name}' is shorter than ${min_length} characters; generate one with: openssl rand -hex 32" >&2
    exit 1
  fi
  hash=$(printf '%s' "$value" | hash_stdin)
  unset value
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || { echo "hashing failed for '${name}'" >&2; exit 1; }
  # The same value pasted for two names would give two names one credential.
  [[ "$hashes" != *" ${hash} "* ]] || { echo "token '${name}' has the same value as another token in this run" >&2; exit 1; }
  hashes+="${hash} "
  printf '%s' "$hash" >"$tmp/hashes/$name"
  from_files+=(--from-file="${name}=${tmp}/hashes/${name}")
done

# --scope strict binds every value to this exact name and namespace.
# --merge-into replaces only the keys given and keeps the others.
sealed="$tmp/sealed.yaml"
secret_json() {
  kubectl create secret generic demo-tokens -n "$ns" \
    --dry-run=client -o json "${from_files[@]}"
}
seal() { kubeseal --cert "$cert" --format yaml --scope strict "$@"; }
if [ -f "$out" ]; then
  cp "$out" "$sealed"
  secret_json | seal --merge-into "$sealed"
else
  secret_json | seal >"$sealed"
fi
grep -q '^kind: SealedSecret' "$sealed" || { echo "output is not a SealedSecret" >&2; exit 1; }
grep -q "^  namespace: ${ns}\$" "$sealed" || { echo "output is not in namespace ${ns}" >&2; exit 1; }
for name in "$@"; do
  # "-" is literal in a key name; there is no "." to escape (name_re).
  grep -q "^    ${name}: " "$sealed" || { echo "token '${name}' is missing from the output" >&2; exit 1; }
done

mv "$sealed" "$out"

# The overlay lists the file under resources. Not appended here: that file ends
# with patches, so a line added at the end would land in the wrong list.
# A trailing comment or spaces after the name are fine (demo #224: a whole-line match
# warned about a file that was listed). The dot in the name is matched literally.
grep -Eq "^[[:space:]]+-[[:space:]]+${entry//./[.]}[[:space:]]*(#.*)?\$" "$kust" || echo "warning: ${entry} is not in ${kust#"$repo"/} resources" >&2
echo "Sealed $# demo token hash(es) -> ${out#"$repo"/}. Review the diff, then commit it."
echo "Give each token's value to its holder; the cluster never sees it."
