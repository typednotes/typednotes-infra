#!/usr/bin/env bash
# Create the vault's service identities (typednotes/typednotes
# docs/connections.md §4): one policy and one userpass user each for the app
# and for liaison. Idempotent — re-running replaces both policies and resets
# both passwords to the values given, which is also how to rotate them.
#
#   SECRETS_URL=https://secrets-server-….functions.fnc.fr-par.scw.cloud \
#   SECRETS_BOOTSTRAP_PASSWORD=… \
#   APP_SECRETS_PASSWORD=…       \
#   LIAISON_SECRETS_PASSWORD=…   \
#     scripts/vault-bootstrap.sh
#
# The two service passwords must be the same values given to `apply` (the
# `app-secrets-password` / `liaison-secrets-password` secrets in Fleet.lean),
# since those are what the containers log in with. Needs secrets-server
# ≥ 1.2.0 (the userpass users endpoint), curl and jq.
#
# | user           | policy         | on secret/data/thirdparty/ |
# |----------------|----------------|----------------------------|
# | typednotes-app | typednotes-app | create, delete — never read |
# | liaison        | liaison        | read, create (Google token write-back) |
set -euo pipefail

: "${SECRETS_URL:?set SECRETS_URL to the vault's https:// URL}"
: "${SECRETS_BOOTSTRAP_PASSWORD:?set SECRETS_BOOTSTRAP_PASSWORD (the vault admin's password)}"
: "${APP_SECRETS_PASSWORD:?set APP_SECRETS_PASSWORD (the app's vault password)}"
: "${LIAISON_SECRETS_PASSWORD:?set LIAISON_SECRETS_PASSWORD (liaison's vault password)}"
admin_user="${SECRETS_ADMIN_USERNAME:-admin}"
url="${SECRETS_URL%/}"

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done
for v in APP_SECRETS_PASSWORD LIAISON_SECRETS_PASSWORD; do
  value="${!v}"
  [ "${#value}" -ge 16 ] || { echo "$v must be at least 16 characters" >&2; exit 2; }
done

# POST $1 with JSON body $2 and bearer $3; fail on a non-2xx, printing the
# vault's error (never a password: bodies here are only echoed on failure,
# and the vault's error messages do not repeat request bodies).
call() {
  local out status
  out="$(mktemp)"
  status="$(curl -sS -o "$out" -w '%{http_code}' -X POST "$url$1" \
    -H 'content-type: application/json' ${3:+-H "authorization: Bearer $3"} \
    --data-binary "$2")"
  if [ "${status:0:1}" != 2 ]; then
    echo "POST $1 → $status: $(cat "$out")" >&2
    rm -f "$out"
    exit 1
  fi
  cat "$out"
  rm -f "$out"
}

token="$(call /v1/auth/userpass/login \
  "$(jq -nc --arg u "$admin_user" --arg p "$SECRETS_BOOTSTRAP_PASSWORD" '{username: $u, password: $p}')" \
  | jq -r .auth.client_token)"
trap 'curl -sS -o /dev/null -X POST "$url/v1/auth/token/revoke-self" -H "authorization: Bearer $token" || true' EXIT

policy() { # name, capabilities (JSON array)
  call "/v1/sys/policy/$1" \
    "$(jq -nc --arg n "$1" --argjson c "$2" \
      '{name: $n, rules: [{prefix: "secret/data/thirdparty/", capabilities: $c}]}')" \
    "$token" >/dev/null
  echo "policy $1: $2 on secret/data/thirdparty/"
}

user() { # name, password, policy
  call "/v1/auth/userpass/users/$1" \
    "$(jq -nc --arg p "$2" --arg pol "$3" '{password: $p, policies: [$pol]}')" \
    "$token" >/dev/null
  echo "user $1 → policy $3"
}

policy typednotes-app '["create","delete"]'
policy liaison '["read","create"]'
user typednotes-app "$APP_SECRETS_PASSWORD" typednotes-app
user liaison "$LIAISON_SECRETS_PASSWORD" liaison
