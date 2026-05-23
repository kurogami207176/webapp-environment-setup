#!/usr/bin/env bash
# bin/deploy-iam-github-actions-user.sh
# ---------------------------------------------------------------------------
# Deploys (or updates) the GitHub Actions IAM user and its managed policies.
# This is a one-time / manual operation — not part of the CI pipeline.
#
# Run this once per AWS account before setting up any GitHub Actions pipelines.
# After deploying, run bin/create-github-actions-credentials.sh to generate
# access keys and push them to GitHub.
#
# Usage:
#   ./bin/deploy-iam-github-actions-user.sh [options]
#
# Options:
#   --app-name   <name>        default: webapp
#   --region     <aws-region>  default: ap-southeast-2
#   --username   <iam-user>    default: github-actions-webapp
#   --dry-run                  validate template only, no deploy
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
APP_NAME="webapp"
REGION="ap-southeast-2"
USERNAME="github-actions-webapp"
DRY_RUN=false

CF_DIR="$(cd "$(dirname "$0")/../cf" && pwd)"
TEMPLATE="${CF_DIR}/iam-github-actions-user.yml"
TAGS_FILE="${CF_DIR}/tags.json"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)  APP_NAME="$2";  shift 2 ;;
    --region)    REGION="$2";    shift 2 ;;
    --username)  USERNAME="$2";  shift 2 ;;
    --dry-run)   DRY_RUN=true;   shift   ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "❌  aws CLI not found. Install: brew install awscli" >&2
  exit 1
fi

if [[ ! -f "${TAGS_FILE}" ]]; then
  echo "❌  Tags file not found: ${TAGS_FILE}" >&2
  exit 1
fi

# ── Resolve account ID ────────────────────────────────────────────────────────
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

STACK_NAME="${APP_NAME}-iam-github-actions-user"

# Convert tags.json → "Key=Value ..." for --tags
TAGS_ARGS=$(python3 -c "
import json
tags = json.load(open('${TAGS_FILE}'))
print(' '.join(f\"{t['Key']}={t['Value']}\" for t in tags))
")

# ── Header ────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " IAM GitHub Actions User Deploy"
echo "  Stack:    ${STACK_NAME}"
echo "  User:     ${USERNAME}"
echo "  Account:  ${ACCOUNT_ID}"
echo "  Region:   ${REGION}"
[[ "${DRY_RUN}" == "true" ]] && echo "  Mode:     DRY RUN (validate only)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Template validation ───────────────────────────────────────────────────────
echo ""
echo "▶ Validating template…"
aws cloudformation validate-template \
  --template-body "file://${TEMPLATE}" \
  --region "${REGION}" \
  --output text > /dev/null
echo "  ✓ Template valid"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "  Dry-run complete — no changes deployed."
  exit 0
fi

# ── Deploy ────────────────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying stack (${STACK_NAME})…"

aws cloudformation deploy \
  --template-file "${TEMPLATE}" \
  --stack-name "${STACK_NAME}" \
  --parameter-overrides \
      "AppName=${APP_NAME}" \
      "AwsAccountId=${ACCOUNT_ID}" \
      "Region=${REGION}" \
      "UserName=${USERNAME}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --tags ${TAGS_ARGS} \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

# ── Show outputs ──────────────────────────────────────────────────────────────
echo ""
echo "▶ Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅  IAM user ready: ${USERNAME}"
echo ""
echo " Next step — generate access keys and push to GitHub:"
echo "   ./bin/create-github-actions-credentials.sh --github-repo <owner/repo>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
