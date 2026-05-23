#!/usr/bin/env bash
# bin/deploy-network.sh
# ---------------------------------------------------------------------------
# Deploys (or updates) the network CloudFormation stack.
#
# Usage:
#   ./bin/deploy-network.sh --env <dev|staging|production> [options]
#
# Options:
#   --env          <dev|staging|production>   required
#   --app-name     <name>                     default: webapp
#   --region       <aws-region>               default: ap-southeast-2
#   --vpc-cidr     <cidr>                     default: 10.0.0.0/16
#   --dry-run                                 validate template only, no deploy
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
APP_NAME="webapp"
ENV=""
REGION="ap-southeast-2"
VPC_CIDR="10.0.0.0/16"
DRY_RUN=false

CF_DIR="$(cd "$(dirname "$0")/../cf" && pwd)"
TEMPLATE="${CF_DIR}/network.yml"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)       ENV="$2";       shift 2 ;;
    --app-name)  APP_NAME="$2";  shift 2 ;;
    --region)    REGION="$2";    shift 2 ;;
    --vpc-cidr)  VPC_CIDR="$2";  shift 2 ;;
    --dry-run)   DRY_RUN=true;   shift   ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "${ENV}" ]]; then
  echo "Usage: $0 --env <dev|staging|production> [--app-name <name>] [--region <region>] [--dry-run]" >&2
  exit 1
fi

if [[ ! "${ENV}" =~ ^(dev|staging|production)$ ]]; then
  echo "❌  --env must be one of: dev, staging, production" >&2
  exit 1
fi

if ! command -v aws &>/dev/null; then
  echo "❌  aws CLI not found. Install: brew install awscli" >&2
  exit 1
fi

STACK_NAME="${APP_NAME}-${ENV}-network"

# ── Header ────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Network Stack Deploy"
echo "  App:    ${APP_NAME}"
echo "  Env:    ${ENV}"
echo "  Stack:  ${STACK_NAME}"
echo "  Region: ${REGION}"
[[ "${DRY_RUN}" == "true" ]] && echo "  Mode:   DRY RUN (validate only)"
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
echo "  This creates a NAT Gateway — allow 2–3 minutes."
echo ""

aws cloudformation deploy \
  --template-file "${TEMPLATE}" \
  --stack-name "${STACK_NAME}" \
  --parameter-overrides \
      "AppName=${APP_NAME}" \
      "Env=${ENV}" \
      "VpcCidr=${VPC_CIDR}" \
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
echo " ✅  Network stack ready: ${STACK_NAME}"
echo ""
echo " Next step:"
echo "   ./bin/deploy-database.sh --env ${ENV} --app-name ${APP_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
