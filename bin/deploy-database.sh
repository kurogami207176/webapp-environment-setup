#!/usr/bin/env bash
# bin/deploy-database.sh
# ---------------------------------------------------------------------------
# Deploys (or updates) the Aurora PostgreSQL Serverless v2 CloudFormation
# stack. All environment-specific values are read from
# cf/params/database.<env>.json. The network stack MUST already exist.
#
# Usage:
#   ./bin/deploy-database.sh --env <dev|staging|production> [options]
#
# Options:
#   --env      <dev|staging|production>  required
#   --region   <aws-region>              default: ap-southeast-2
#   --dry-run                            validate template only, no deploy
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
ENV=""
REGION="ap-southeast-2"
DRY_RUN=false

CF_DIR="$(cd "$(dirname "$0")/../cf" && pwd)"
TEMPLATE="${CF_DIR}/database.yml"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)     ENV="$2";     shift 2 ;;
    --region)  REGION="$2";  shift 2 ;;
    --dry-run) DRY_RUN=true; shift   ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "${ENV}" ]]; then
  echo "Usage: $0 --env <dev|staging|production> [--region <region>] [--dry-run]" >&2
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

# ── Resolve parameter file ────────────────────────────────────────────────────
PARAM_FILE="${CF_DIR}/params/database.${ENV}.json"
if [[ ! -f "${PARAM_FILE}" ]]; then
  echo "❌  Parameter file not found: ${PARAM_FILE}" >&2
  exit 1
fi

# Read AppName out of the param file
APP_NAME=$(python3 -c "
import json, sys
params = json.load(open('${PARAM_FILE}'))
match = next((p['ParameterValue'] for p in params if p['ParameterKey'] == 'AppName'), None)
if not match:
    sys.exit('AppName not found in ${PARAM_FILE}')
print(match)
")

NETWORK_STACK="${APP_NAME}-${ENV}-network"
STACK_NAME="${APP_NAME}-${ENV}-database"

# ── Guard: network stack must exist first ─────────────────────────────────────
check_network_stack() {
  echo "▶ Checking network stack (${NETWORK_STACK})…"
  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "${NETWORK_STACK}" \
    --region "${REGION}" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [[ "${status}" == "DOES_NOT_EXIST" ]]; then
    echo "❌  Network stack '${NETWORK_STACK}' does not exist." >&2
    echo "    Run first: ./bin/deploy-network.sh --env ${ENV}" >&2
    exit 1
  fi

  if [[ "${status}" != "CREATE_COMPLETE" && "${status}" != "UPDATE_COMPLETE" ]]; then
    echo "❌  Network stack '${NETWORK_STACK}' is in status: ${status}" >&2
    echo "    Wait for it to reach CREATE_COMPLETE or UPDATE_COMPLETE before continuing." >&2
    exit 1
  fi
  echo "  ✓ Network stack ready (${status})"
}

# ── Header ────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Database Stack Deploy"
echo "  Stack:  ${STACK_NAME}"
echo "  Region: ${REGION}"
echo "  Params: cf/params/database.${ENV}.json"
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

check_network_stack

# ── Deploy ────────────────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying stack (${STACK_NAME})…"
echo "  Aurora cluster creation takes ~5–10 minutes."
echo ""

aws cloudformation deploy \
  --template-file "${TEMPLATE}" \
  --stack-name "${STACK_NAME}" \
  --parameter-overrides "file://${PARAM_FILE}" \
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
echo "▶ Secrets Manager entries:"
echo "  Master credentials : /${APP_NAME}/${ENV}/database/master"
echo "  App connection     : /${APP_NAME}/${ENV}/database/app"
echo ""
echo "▶ Fetch credentials:"
echo "  aws secretsmanager get-secret-value \\"
echo "    --secret-id /${APP_NAME}/${ENV}/database/master \\"
echo "    --region ${REGION} \\"
echo "    --query SecretString --output text | python3 -m json.tool"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅  Database stack ready: ${STACK_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
