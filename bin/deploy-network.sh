#!/usr/bin/env bash
# bin/deploy-network.sh
# ---------------------------------------------------------------------------
# Deploys (or updates) the network CloudFormation stack.
# All environment-specific values are read from cf/params/network.<env>.json.
#
# Usage:
#   ./bin/deploy-network.sh --env <dev|staging|production> [options]
#
# Options:
#   --env       <dev|staging|production>  required
#   --region    <aws-region>              default: ap-southeast-2
#   --dry-run                             validate template only, no deploy
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
ENV=""
REGION="ap-southeast-2"
DRY_RUN=false

CF_DIR="$(cd "$(dirname "$0")/../cf" && pwd)"
TEMPLATE="${CF_DIR}/network.yml"
TAGS_FILE="${CF_DIR}/tags.json"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)     ENV="$2";    shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift  ;;
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
PARAM_FILE="${CF_DIR}/params/network.${ENV}.json"
if [[ ! -f "${PARAM_FILE}" ]]; then
  echo "❌  Parameter file not found: ${PARAM_FILE}" >&2
  exit 1
fi

if [[ ! -f "${TAGS_FILE}" ]]; then
  echo "❌  Tags file not found: ${TAGS_FILE}" >&2
  exit 1
fi

# Convert tags.json [ {"Key":...,"Value":...} ] → "Key=Value Key=Value ..." for --tags
TAGS_ARGS=$(python3 -c "
import json
tags = json.load(open('${TAGS_FILE}'))
print(' '.join(f\"{t['Key']}={t['Value']}\" for t in tags))
")

# Read AppName out of the param file (avoids duplicating it as a script arg)
APP_NAME=$(python3 -c "
import json, sys
params = json.load(open('${PARAM_FILE}'))
match = next((p['ParameterValue'] for p in params if p['ParameterKey'] == 'AppName'), None)
if not match:
    sys.exit('AppName not found in ${PARAM_FILE}')
print(match)
")

STACK_NAME="${APP_NAME}-${ENV}-network"

# ── Header ────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Network Stack Deploy"
echo "  Stack:  ${STACK_NAME}"
echo "  Region: ${REGION}"
echo "  Params: cf/params/network.${ENV}.json"
echo "  Tags:   cf/tags.json"
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
  --parameter-overrides "file://${PARAM_FILE}" \
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
echo " ✅  Network stack ready: ${STACK_NAME}"
echo ""
echo " Next step:"
echo "   ./bin/deploy-database.sh --env ${ENV}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
