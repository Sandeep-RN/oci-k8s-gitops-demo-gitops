#!/usr/bin/env bash
# Seal the on-call assistant's Secrets into its k3s overlay (demo #195,
# ADR 0006, ADR 0025). Sealing needs no cluster access: it uses this cluster's
# public certificate.
#
#   postgres-credentials          admin (superuser), username oncall_admin
#   postgres-indexer-credentials  index CronJob,     username oncall_indexer
#   postgres-app-credentials      app, read-only,    username oncall_app
#   groq-api-key                  key GROQ_API_KEY,  from a hidden prompt
#
# The three database passwords are GENERATED here (openssl rand) and never
# shown or stored anywhere else: the database is a cache (ADR 0025), and the
# admin can still reach it with `kubectl exec` and psql over the local socket.
# Only the Groq key is pasted (keep it in the password manager). Values never
# reach shell history, argv, logs or Git in plaintext. They do touch disk
# briefly: private (mode 600) temp files, which kubectl reads, removed on exit.
#
# Usage:
#   scripts/seal-oncall-secrets.sh          create every Secret file that is missing
#   scripts/seal-oncall-secrets.sh NAME...  re-seal these (rotate), e.g. groq-api-key
#
# Rotation:
#   - groq-api-key, postgres-indexer-credentials, postgres-app-credentials:
#     re-seal by name and merge. The oncall-db-roles Job sets the new database
#     passwords on the next sync. Pods read Secrets as environment variables
#     only at start, so ArgoCD's sync does not restart them: restart the app
#     (or wait for the next deploy) after a Groq or app password change.
#   - postgres-credentials (admin) is REFUSED: Postgres reads it only at initdb,
#     so a new value would lock the role Job out. To rotate it, delete the file,
#     run this script, merge, then in a planned sitting delete the PVC
#     data-postgres-0 and the pod postgres-0 so initdb runs again, and start an
#     index Job (the database is a cache).
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cert="${repo}/argocd/clusters/k3s/sealed-secrets-cert.pem"
dir="${repo}/apps/oncall-assistant/overlays/k3s"
kust="${dir}/kustomization.yaml"
ns=oncall-assistant
all=(postgres-credentials postgres-indexer-credentials postgres-app-credentials groq-api-key)
declare -A db_user=(
  [postgres-credentials]=oncall_admin
  [postgres-indexer-credentials]=oncall_indexer
  [postgres-app-credentials]=oncall_app
)
file_for() { echo "${dir}/$1-sealedsecret.yaml"; }

for tool in kubeseal kubectl openssl; do
  command -v "$tool" >/dev/null || { echo "$tool not found" >&2; exit 1; }
done
[ -f "$cert" ] || { echo "missing $cert" >&2; exit 1; }

targets=()
if [ $# -eq 0 ]; then
  for name in "${all[@]}"; do
    [ -f "$(file_for "$name")" ] || targets+=("$name")
  done
  if [ ${#targets[@]} -eq 0 ]; then
    echo "All four Secret files exist; nothing to do. To rotate one: $0 NAME"
    exit 0
  fi
else
  for name in "$@"; do
    case " ${all[*]} " in *" ${name} "*) ;; *) echo "unknown Secret: ${name} (one of: ${all[*]})" >&2; exit 2 ;; esac
    if [ "$name" = postgres-credentials ] && [ -f "$(file_for "$name")" ]; then
      echo "refusing to re-seal postgres-credentials: Postgres reads the admin password only at initdb; see this script's header" >&2
      exit 2
    fi
    case " ${targets[*]-} " in *" ${name} "*) echo "given twice: ${name}" >&2; exit 2 ;; esac
    targets+=("$name")
  done
fi

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Ask for the only pasted value first, so a bad paste stops the run before
# anything is generated or written.
case " ${targets[*]} " in *" groq-api-key "*)
  read -r -s -p "Groq API key (hidden): " value
  echo >&2
  value=${value%$'\r'} # a paste from Windows can carry a CR
  if [[ "$value" =~ [[:space:]] ]]; then echo "the key contains whitespace; paste the key only" >&2; exit 1; fi
  if [[ "$value" != gsk_* ]]; then echo "a Groq key starts with gsk_; check what was pasted" >&2; exit 1; fi
  if [ "${#value}" -lt 40 ]; then echo "the key is only ${#value} characters; check what was pasted" >&2; exit 1; fi
  printf '%s' "$value" >"$tmp/groq"
  unset value
  ;;
esac

# --scope strict binds each value to this exact name and namespace.
for name in "${targets[@]}"; do
  if [ "$name" = groq-api-key ]; then
    from=(--from-file="GROQ_API_KEY=${tmp}/groq")
    keys=(GROQ_API_KEY)
  else
    printf '%s' "${db_user[$name]}" >"$tmp/${name}.user"
    # 48 hex characters: no quoting or URL-escaping problems anywhere.
    openssl rand -hex 24 | tr -d '\r\n' >"$tmp/${name}.pass"
    [ "$(wc -c <"$tmp/${name}.pass")" -eq 48 ] || { echo "password generation failed" >&2; exit 1; }
    from=(--from-file="username=${tmp}/${name}.user" --from-file="password=${tmp}/${name}.pass")
    keys=(username password)
  fi
  kubectl create secret generic "$name" -n "$ns" --dry-run=client -o json "${from[@]}" |
    kubeseal --cert "$cert" --format yaml --scope strict >"$tmp/${name}.yaml"
  grep -q '^kind: SealedSecret' "$tmp/${name}.yaml" || { echo "${name}: output is not a SealedSecret" >&2; exit 1; }
  grep -q "^  namespace: ${ns}\$" "$tmp/${name}.yaml" || { echo "${name}: not in namespace ${ns}" >&2; exit 1; }
  for k in "${keys[@]}"; do
    grep -q "^    ${k}: " "$tmp/${name}.yaml" || { echo "${name}: key ${k} is missing from the output" >&2; exit 1; }
  done
done

# Every file sealed: only now replace anything in the repo.
for name in "${targets[@]}"; do
  mv "$tmp/${name}.yaml" "$(file_for "$name")"
  entry="$(basename "$(file_for "$name")")"
  grep -q "^  - ${entry}" "$kust" || echo "warning: ${entry} is not in ${kust#"$repo"/} resources" >&2
  echo "sealed: ${name} -> ${dir#"$repo"/}/${entry}"
done
echo "Review with git status / git diff, then hand over for the commit."
