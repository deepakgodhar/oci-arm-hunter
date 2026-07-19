#!/usr/bin/env bash
#
# set-secrets.sh — push your OCI credentials to this repo's GitHub Actions secrets.
#
# 1. Copy .env.example to .env and fill it in (NEVER commit .env).
# 2. Run:  bash scripts/set-secrets.sh
#
# Requires the GitHub CLI (`gh`) authenticated: run `gh auth login` first.

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No .env found. Copy .env.example to .env and fill it in first." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

: "${OCI_CLI_USER:?}"; : "${OCI_CLI_TENANCY:?}"; : "${OCI_CLI_FINGERPRINT:?}"
: "${OCI_CLI_REGION:?}"; : "${OCI_KEY_FILE:?path to your private key PEM}"

gh secret set OCI_CLI_USER        --body "$OCI_CLI_USER"
gh secret set OCI_CLI_TENANCY     --body "$OCI_CLI_TENANCY"
gh secret set OCI_CLI_FINGERPRINT --body "$OCI_CLI_FINGERPRINT"
gh secret set OCI_CLI_REGION      --body "$OCI_CLI_REGION"
gh secret set OCI_CLI_KEY_CONTENT < "$OCI_KEY_FILE"

echo "Done. Secrets set on $(gh repo view --json nameWithOwner -q .nameWithOwner)."
