#!/usr/bin/env bash
# Check the selected architecture before building or creating cloud resources.
set -euo pipefail
required=(SCW_ACCESS_KEY SCW_SECRET_KEY SCW_DEFAULT_PROJECT_ID SCW_DEFAULT_ORGANIZATION_ID
  SECRETS_MASTER_KEY SECRETS_BOOTSTRAP_PASSWORD LIAISON_ROOT_KEY
  APP_SECRETS_PASSWORD LIAISON_SECRETS_PASSWORD LUN_SECRETS_PASSWORD
  LODE_TOKEN LUN_TOKEN LUN_ID_SALT GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET
  GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GITLAB_CLIENT_ID GITLAB_CLIENT_SECRET
  DROPBOX_CLIENT_ID DROPBOX_CLIENT_SECRET SLACK_CLIENT_ID SLACK_CLIENT_SECRET
  SLACK_SIGNING_SECRET WHATSAPP_APP_SECRET WHATSAPP_VERIFY_TOKEN)
case "${TYPEDNOTES_DEPLOYMENT:-lite}" in
  lite|lite-storage) ;;
  full|full-from-lite) required+=(COMPUTE_DB_PASSWORD DB_INSPECTOR_USERNAME DB_INSPECTOR_PASSWORD) ;;
  *) echo 'TYPEDNOTES_DEPLOYMENT must be lite, full-from-lite, full or lite-storage' >&2; exit 1 ;;
esac
missing=()
for key in "${required[@]}"; do
  [ -n "${!key:-}" ] || missing+=("$key")
done
if [ ${#missing[@]} -ne 0 ]; then
  echo "Missing repo secrets: ${missing[*]}" >&2
  exit 1
fi
if [[ "${TYPEDNOTES_DEPLOYMENT:-lite}" = full* ]]; then
  if [[ ${#COMPUTE_DB_PASSWORD} -lt 8 || ${#COMPUTE_DB_PASSWORD} -gt 128 ||
        ! "$COMPUTE_DB_PASSWORD" =~ [[:upper:]] || ! "$COMPUTE_DB_PASSWORD" =~ [[:lower:]] ||
        ! "$COMPUTE_DB_PASSWORD" =~ [[:digit:]] || ! "$COMPUTE_DB_PASSWORD" =~ [^[:alnum:]] ]]; then
    echo 'COMPUTE_DB_PASSWORD must contain 8–128 characters including uppercase, lowercase, a digit and a special character.' >&2
    exit 1
  fi
fi
for key in LODE_TOKEN LUN_TOKEN LUN_ID_SALT LUN_SECRETS_PASSWORD; do
  value="${!key}"
  if [ ${#value} -lt 32 ]; then
    echo "$key must contain at least 32 characters." >&2
    exit 1
  fi
done
echo "Required secrets for ${TYPEDNOTES_DEPLOYMENT:-lite} are present."
