#!/usr/bin/env bash
# bin/create-github-actions-credentials.sh
# ---------------------------------------------------------------------------
# Creates a new AWS access key for the GitHub Actions IAM user and pushes
# the credentials directly into the target GitHub repository's secrets.
#
# Safe to re-run: if the user already has 2 keys (AWS maximum), the script
# will prompt before deleting the oldest one to make room.
#
# This is a manual, one-time operation — not part of the CI pipeline.
#
# Usage:
#   ./bin/create-github-actions-credentials.sh --github-repo <owner/repo> [options]
#
# Options:
#   --github-repo  <owner/repo>   required
#   --username     <iam-user>     default: github-actions-webapp
#   --region       <aws-region>   default: ap-southeast-2
#   --github-env   <env-name>     push into a GitHub Environment instead of repo-level
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
GITHUB_REPO=""
USERNAME="github-actions-webapp"
REGION="ap-southeast-2"
GITHUB_ENV=""

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --github-repo) GITHUB_REPO="$2"; shift 2 ;;
    --username)    USERNAME="$2";    shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    --github-env)  GITHUB_ENV="$2";  shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "${GITHUB_REPO}" ]]; then
  echo "Usage: $0 --github-repo <owner/repo> [--username <user>] [--region <region>] [--github-env <env>]" >&2
  exit 1
fi

for cmd in aws gh python3; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "❌  Required tool not found: ${cmd}" >&2
    exit 1
  fi
done

if ! gh auth status &>/dev/null; then
  echo "❌  gh CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

# ── Header ────────────────────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Create GitHub Actions Credentials"
echo "  IAM User:    ${USERNAME}"
echo "  Account:     ${ACCOUNT_ID}"
echo "  Region:      ${REGION}"
echo "  GitHub Repo: ${GITHUB_REPO}"
[[ -n "${GITHUB_ENV}" ]] && echo "  GitHub Env:  ${GITHUB_ENV}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Check existing keys ───────────────────────────────────────────────────────
echo ""
echo "▶ Checking existing access keys for ${USERNAME}…"

EXISTING_KEYS=$(aws iam list-access-keys \
  --user-name "${USERNAME}" \
  --query 'AccessKeyMetadata[*].[AccessKeyId,Status,CreateDate]' \
  --output text)

KEY_COUNT=$(aws iam list-access-keys \
  --user-name "${USERNAME}" \
  --query 'length(AccessKeyMetadata)' \
  --output text)

echo "  Found ${KEY_COUNT} existing key(s)"

if [[ "${KEY_COUNT}" -gt 0 ]]; then
  echo ""
  echo "  Existing keys:"
  echo "${EXISTING_KEYS}" | while read -r key_id status created; do
    echo "    ${key_id}  status=${status}  created=${created}"
  done
fi

# AWS IAM hard limit: 2 access keys per user
if [[ "${KEY_COUNT}" -ge 2 ]]; then
  echo ""
  echo "⚠️   IAM users may have at most 2 access keys."
  echo "  The oldest key will be deleted to make room."
  echo ""

  OLDEST_KEY=$(aws iam list-access-keys \
    --user-name "${USERNAME}" \
    --query 'sort_by(AccessKeyMetadata, &CreateDate)[0].AccessKeyId' \
    --output text)

  read -r -p "  Delete key ${OLDEST_KEY} and continue? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    echo "  Aborted."
    exit 0
  fi

  echo "  Deleting ${OLDEST_KEY}…"
  aws iam delete-access-key \
    --user-name "${USERNAME}" \
    --access-key-id "${OLDEST_KEY}"
  echo "  ✓ Deleted"
fi

# ── Create new access key ─────────────────────────────────────────────────────
echo ""
echo "▶ Creating new access key…"

KEY_JSON=$(aws iam create-access-key \
  --user-name "${USERNAME}" \
  --output json)

ACCESS_KEY_ID=$(echo "${KEY_JSON}" | python3 -c "import json,sys; k=json.load(sys.stdin)['AccessKey']; print(k['AccessKeyId'])")
SECRET_ACCESS_KEY=$(echo "${KEY_JSON}" | python3 -c "import json,sys; k=json.load(sys.stdin)['AccessKey']; print(k['SecretAccessKey'])")

echo "  ✓ Access key created: ${ACCESS_KEY_ID}"

# ── Push to GitHub ────────────────────────────────────────────────────────────
echo ""
echo "▶ Pushing credentials to GitHub (${GITHUB_REPO})…"

set_secret() {
  local name="$1" value="$2"
  if [[ -n "${GITHUB_ENV}" ]]; then
    echo "  → [env: ${GITHUB_ENV}] secret  ${name}"
    gh secret set "${name}" --repo "${GITHUB_REPO}" --env "${GITHUB_ENV}" --body "${value}"
  else
    echo "  → [repo] secret  ${name}"
    gh secret set "${name}" --repo "${GITHUB_REPO}" --body "${value}"
  fi
}

set_variable() {
  local name="$1" value="$2"
  if [[ -n "${GITHUB_ENV}" ]]; then
    echo "  → [env: ${GITHUB_ENV}] variable ${name}"
    gh variable set "${name}" --repo "${GITHUB_REPO}" --env "${GITHUB_ENV}" --body "${value}"
  else
    echo "  → [repo] variable ${name}"
    gh variable set "${name}" --repo "${GITHUB_REPO}" --body "${value}"
  fi
}

set_secret  "AWS_ACCESS_KEY_ID"     "${ACCESS_KEY_ID}"
set_secret  "AWS_SECRET_ACCESS_KEY" "${SECRET_ACCESS_KEY}"
set_secret  "AWS_ACCOUNT_ID"        "${ACCOUNT_ID}"
set_variable "AWS_REGION"           "${REGION}"

# ── Store key ID in SSM for future reference (not the secret) ─────────────────
echo ""
echo "▶ Storing key ID in SSM (for audit / rotation tracking)…"
aws ssm put-parameter \
  --name "/github-actions/access-key-id" \
  --value "${ACCESS_KEY_ID}" \
  --type String \
  --description "Current GitHub Actions IAM access key ID (not the secret)" \
  --overwrite \
  --region "${REGION}" > /dev/null
echo "  ✓ Stored at /github-actions/access-key-id"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅  Done!"
echo ""
echo " GitHub secrets set : AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ACCOUNT_ID"
echo " GitHub variable set: AWS_REGION"
echo ""
echo " ⚠️  The secret access key is NOT stored anywhere else."
echo "    If it is lost, delete this key and run this script again."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
