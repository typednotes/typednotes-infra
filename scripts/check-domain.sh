#!/usr/bin/env bash
# Check — and with --fix, repair — everything between a browser and the app
# at https://app.typednotes.com that `infra` does not declare (README,
# "Custom domain"): the DNS record, the container's domain binding and its
# TLS certificate, HTTPS-only, and that the app answers on it.
#
#   scripts/check-domain.sh           # read-only; exits 1 if anything is wrong
#   scripts/check-domain.sh --fix     # also repairs what Scaleway can repair
#
# --fix repoints the CNAME at the current container, replaces a stale or
# failed domain binding (waiting for its certificate), and turns on
# HTTPS-only. It changes nothing that already checks out, so it is safe to
# re-run — after every apply that may have recreated `typednotes-app`, for
# instance. Needs a configured `scw` (checked with 2.62), jq, dig, curl and
# openssl.
#
# Overrides: APP_HOSTNAME (app.typednotes.com), DNS_ZONE (typednotes.com),
# APP_CONTAINER (typednotes-app), SCW_REGION (fr-par), MIN_CERT_DAYS (14).
set -euo pipefail

hostname="${APP_HOSTNAME:-app.typednotes.com}"
zone="${DNS_ZONE:-typednotes.com}"
container_name="${APP_CONTAINER:-typednotes-app}"
region="${SCW_REGION:-fr-par}"
min_cert_days="${MIN_CERT_DAYS:-14}"

fix=0
case "${1:-}" in
  --fix) fix=1 ;;
  "") ;;
  *) echo "usage: $0 [--fix]" >&2; exit 2 ;;
esac

for tool in scw jq dig curl openssl; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

case "$hostname" in
  *".$zone") record="${hostname%".$zone"}" ;;
  *) echo "$hostname is not in the zone $zone" >&2; exit 2 ;;
esac

failures=0
ok() { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
step() { printf '\n%s\n' "$*"; }
doing() { printf '  fix   %s\n' "$*"; }

# Retry `$@` every 10 s, up to $1 times.
retry() {
  local tries=$1; shift
  for ((i = 0; i < tries; i++)); do
    if "$@"; then return 0; fi
    sleep 10
  done
  return 1
}

container_json() { scw container container get "$container_id" region="$region" -o json; }
container_ready() { [ "$(container_json | jq -r .status)" = ready ]; }

# ── 1. The container ────────────────────────────────────────────────────
step "Container $container_name"
ids="$(scw container container list name="$container_name" region="$region" -o json \
  | jq -r --arg n "$container_name" '.[] | select(.name == $n) | .id')"
if [ "$(printf '%s' "$ids" | grep -c .)" != 1 ]; then
  fail "expected exactly one container named $container_name, found: ${ids:-none}"
  exit 1
fi
container_id="$ids"
info="$(container_json)"
scw_host="$(jq -r '(.public_endpoint // .domain_name) | sub("^https://"; "")' <<<"$info")"
status="$(jq -r .status <<<"$info")"
[ "$status" = ready ] && ok "$container_id is ready ($scw_host)" || fail "$container_id is $status"

public_url="$(jq -r '.environment_variables.PUBLIC_URL // empty' <<<"$info")"
if [ "$public_url" = "https://$hostname" ]; then
  ok "PUBLIC_URL is https://$hostname"
else
  # Fleet.lean's appPublicUrl; every OAuth redirect URI is built from it.
  fail "PUBLIC_URL is '${public_url:-unset}', not https://$hostname (appPublicUrl in Fleet.lean, then apply)"
fi

# ── 2. DNS ──────────────────────────────────────────────────────────────
# Asked of the zone's own name servers, so a fix shows up without waiting
# for resolver caches; a public resolver's answer is reported alongside.
step "DNS $hostname"
nameserver="$(dig +short NS "$zone" | head -1)"
authoritative() { dig +short CNAME "$hostname" ${nameserver:+@"$nameserver"} | head -1; }
cname_is_right() { [ "$(authoritative)" = "$scw_host." ]; }

if cname_is_right; then
  ok "CNAME → $scw_host (at ${nameserver:-the default resolver})"
elif [ "$fix" = 1 ]; then
  doing "CNAME was '$(authoritative)', setting it to $scw_host."
  scw dns record set "$zone" name="$record" type=CNAME values.0="$scw_host." ttl=300 >/dev/null
  if retry 30 cname_is_right; then
    ok "CNAME → $scw_host"
  else
    fail "CNAME still answers '$(authoritative)' after 5 minutes"
  fi
else
  fail "CNAME is '$(authoritative)', not $scw_host. (--fix sets it)"
fi
public="$(dig +short CNAME "$hostname" @1.1.1.1 | head -1)"
[ "$public" = "$scw_host." ] || warn "1.1.1.1 still answers '$public' (TTL 300 s: resolvers catch up)"

# ── 3. The domain binding and its certificate ───────────────────────────
step "Domain binding"
bindings() {
  scw container domain list region="$region" -o json \
    | jq -c --arg h "$hostname" '[.[] | select(.hostname == $h)]'
}
binding_status() { bindings | jq -r --arg c "$container_id" '.[] | select(.container_id == $c) | .status'; }
binding_is_ready() { [ "$(bindings | jq length)" = 1 ] && [ "$(binding_status)" = ready ]; }
bindings_gone() { [ "$(bindings | jq length)" = 0 ]; }
binding_settled() { case "$(binding_status)" in ready | error) return 0 ;; *) return 1 ;; esac; }

current="$(bindings)"
describe="$(jq -r '[.[] | "\(.container_id[0:8])… \(.status)\(if (.error_message // "") != "" then " (" + .error_message + ")" else "" end)"] | join(", ")' <<<"$current")"
if binding_is_ready; then
  ok "$hostname is bound to $container_id and ready"
elif [ "$fix" = 1 ]; then
  if ! cname_is_right; then
    # Binding before the CNAME resolves makes certificate issuance fail,
    # and a failed binding is never retried.
    fail "not binding while the CNAME is wrong"
  else
    doing "bindings were: ${describe:-none}; recreating"
    jq -r '.[].id' <<<"$current" | while read -r id; do
      scw container domain delete "$id" region="$region" >/dev/null
    done
    retry 30 bindings_gone || fail "old binding still deleting after 5 minutes"
    scw container domain create container-id="$container_id" hostname="$hostname" region="$region" >/dev/null
    # Issuing the certificate takes a few minutes.
    retry 60 binding_settled || true
    if binding_is_ready; then
      ok "$hostname is bound to $container_id and ready"
    else
      fail "binding is '$(binding_status)': $(bindings | jq -r '(.[0].error_message // "") | if . == "" then "no error message" else . end')"
    fi
  fi
else
  fail "expected one ready binding to $container_id, found: ${describe:-none} (--fix recreates it)"
fi

step "TLS certificate"
cert="$(openssl s_client -connect "$hostname:443" -servername "$hostname" -verify_return_error </dev/null 2>/dev/null \
  | openssl x509 2>/dev/null || true)"
if [ -z "$cert" ]; then
  fail "no certificate that verifies is served for $hostname"
else
  issuer="$(openssl x509 -noout -issuer <<<"$cert" | sed 's/^issuer= *//')"
  expiry="$(openssl x509 -noout -enddate <<<"$cert" | sed 's/^notAfter=//')"
  if openssl x509 -noout -ext subjectAltName <<<"$cert" 2>/dev/null | grep -q "DNS:$hostname"; then
    ok "verifies, covers $hostname ($issuer)"
  else
    fail "the certificate does not name $hostname"
  fi
  if openssl x509 -noout -checkend $((min_cert_days * 86400)) <<<"$cert" >/dev/null; then
    ok "valid until $expiry"
  else
    # Scaleway renews it itself; one this close to expiry means it did not.
    fail "expires $expiry, within $min_cert_days days (recreating the binding reissues it: --fix after deleting it)"
  fi
fi

# ── 4. HTTPS only ───────────────────────────────────────────────────────
# `https_connection_only` reads back null from the API even when on, so
# this checks the behaviour: plain HTTP must be redirected, not served.
step "HTTPS only"
redirect() { curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://$hostname/"; }
redirects() { [ "$(redirect)" = "301 https://$hostname/" ]; }
if redirects; then
  ok "http:// → 301 https://$hostname/"
elif [ "$fix" = 1 ]; then
  doing "http:// answered '$(redirect)'; turning on https-connection-only"
  scw container container update "$container_id" region="$region" https-connection-only=true >/dev/null
  retry 30 container_ready || true
  if retry 6 redirects; then
    ok "http:// → 301 https://$hostname/"
  else
    fail "http:// still answers '$(redirect)'"
  fi
else
  fail "http:// answers '$(redirect)' — the app is served unencrypted (--fix turns on https-connection-only)"
fi

# ── 5. The app, through all of it ───────────────────────────────────────
step "App"
health="$(curl -s --max-time 60 -w '\n%{http_code}' "https://$hostname/api/health" || true)"
code="$(tail -n1 <<<"$health")"
body="$(sed '$d' <<<"$health")"
if [ "$code" = 200 ] && jq -e . >/dev/null 2>&1 <<<"$body"; then
  ok "https://$hostname/api/health answers 200"
  off="$(jq -r 'to_entries | map(select(.value == false) | .key) | join(", ")' <<<"$body")"
  [ -z "$off" ] && ok "every dependency is up" || warn "reported off: $off"
else
  fail "https://$hostname/api/health answered ${code:-nothing}"
fi

echo
if [ "$failures" = 0 ]; then
  echo "All good: https://$hostname"
else
  echo "$failures problem(s)."
  [ "$fix" = 1 ] || echo "Run with --fix to repair what can be repaired from here."
  exit 1
fi
