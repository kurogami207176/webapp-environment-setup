#!/usr/bin/env bash
# bin/sync-ssm-to-github.sh
# ---------------------------------------------------------------------------
# Pulls AWS SSM Parameter Store values under /github-actions/* and pushes
# them into a GitHub repository as:
#   - Secrets  → aws-access-key-id, aws-secret-access-key, aws-account-id
#   - Variables → aws-region   (plain text, not sensitive)
#
# Usage:
#   ./bin/sync-ssm-to-github.sh --github-repo <owner/repo> [--region <region>] [--env <environment>]
#
# Requirements:
#   - aws CLI authenticated (profile or env vars)
#   - gh CLI authenticated (`gh auth login`)
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
REGION="ap-southeast-2"
GITHUB_REPO=""
ENVIRONMENT=""          # optional: push into a GitHub Environment instead of repo-level

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    --env)         ENVIRONMENT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${GITHUB_REPO}" ]]; then
  echo "Usage: $0 --github-repo <owner/repo> [--region <region>] [--env <environment>]" >&2
  exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in aws gh; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "❌  Missing required tools: ${missing[*]}" >&2
    echo "    Install: brew install awscli gh" >&2
    exit 1
  fi
}

fetch_ssm() {
  local param_name="$1"
  aws ssm get-parameter \
    --name "${param_name}" \
    --with-decryption \
    --region "${REGION}" \
    --query 'Parameter.Value' \
    --output text
}

set_secret() {
  local secret_name="$1"
  local secret_value="$2"
  if [[ -n "${ENVIRONMENT}" ]]; then
    echo "  → [env: ${ENVIRONMENT}] secret  ${secret_name}"
    gh secret set "${secret_name}" \
      --repo "${GITHUB_REPO}" \
      --env  "${ENVIRONMENT}" \
      --body "${secret_value}"
  else
    echo "  → [repo] secret  ${secret_name}"
    gh secret set "${secret_name}" \
      --repo "${GITHUB_REPO}" \
      --body "${secret_value}"
  fi
}

set_variable() {
  local var_name="$1"
  local var_value="$2"
  if [[ -n "${ENVIRONMENT}" ]]; then
    echo "  → [env: ${ENVIRONMENT}] variable ${var_name}"
    gh variable set "${var_name}" \
      --repo "${GITHUB_REPO}" \
      --env  "${ENVIRONMENT}" \
      --body "${var_value}"
  else
    echo "  → [repo] variable ${var_name}"
    gh variable set "${var_name}" \
      --repo "${GITHUB_REPO}" \
      --body "${var_value}"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
check_deps

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Syncing SSM → GitHub  (${GITHUB_REPO})"
[[ -n "${ENVIRONMENT}" ]] && echo " Environment: ${ENVIRONMENT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "▶ Fetching SSM parameters (region: ${REGION})…"

AWS_ACCESS_KEY_ID_VAL=$(fetch_ssm "/github-actions/aws-access-key-id")
AWS_SECRET_ACCESS_KEY_VAL=$(fetch_ssm "/github-actions/aws-secret-access-key")
AWS_ACCOUNT_ID_VAL=$(fetch_ssm "/github-actions/aws-account-id")
AWS_REGION_VAL=$(fetch_ssm "/github-actions/aws-region")

echo "  ✓ All 4 parameters fetched"

echo ""
echo "▶ Pushing to GitHub…"

# Secrets (sensitive — stored encrypted by GitHub)
set_secret "AWS_ACCESS_KEY_ID"     "${AWS_ACCESS_KEY_ID_VAL}"
set_secret "AWS_SECRET_ACCESS_KEY" "${AWS_SECRET_ACCESS_KEY_VAL}"
set_secret "AWS_ACCOUNT_ID"        "${AWS_ACCOUNT_ID_VAL}"

# Variable (non-sensitive — stored as plaintext GitHub variable)
set_variable "AWS_REGION" "${AWS_REGION_VAL}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅  Done!"
echo ""
echo " Secrets set  : AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ACCOUNT_ID"
echo " Variables set: AWS_REGION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
