#!/usr/bin/env bash
# bin/deploy-dns-config.sh
# ---------------------------------------------------------------------------
# Deploys shared DNS configuration (hosted zone ID + domain name) as SSM
# parameters so application repos can reference them without hard-coding.
#
# Deploy once per AWS account — not per environment.
#
# Usage:
#   ./bin/deploy-dns-config.sh [--region <region>] [--dry-run]
# ---------------------------------------------------------------------------
set -euo pipefail

REGION="ap-southeast-2"
DRY_RUN=false

CF_DIR="$(cd "$(dirname "$0")/../cf" && pwd)"
TEMPLATE="${CF_DIR}/dns-config.yml"
PARAM_FILE="${CF_DIR}/params/dns-config.json"
TAGS_FILE="${CF_DIR}/tags.json"
STACK_NAME="dns-config"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)  REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift  ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if ! command -v aws &>/dev/null; then
  echo "❌  aws CLI not found." >&2; exit 1
fi

TAGS_ARGS=$(python3 -c "
import json
tags = json.load(open('${TAGS_FILE}'))
print(' '.join(f\"{t['Key']}={t['Value']}\" for t in tags))
")

DOMAIN=$(python3 -c "
import json
params = json.load(open('${PARAM_FILE}'))
print(next(p['ParameterValue'] for p in params if p['ParameterKey'] == 'DomainName'))
")

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " DNS Config Deploy"
echo "  Stack:  ${STACK_NAME}"
echo "  Domain: ${DOMAIN}"
echo "  Region: ${REGION}"
echo "  Params: cf/params/dns-config.json"
[[ "${DRY_RUN}" == "true" ]] && echo "  Mode:   DRY RUN (validate only)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

echo ""
echo "▶ Deploying stack (${STACK_NAME})…"

aws cloudformation deploy \
  --template-file "${TEMPLATE}" \
  --stack-name "${STACK_NAME}" \
  --parameter-overrides "file://${PARAM_FILE}" \
  --tags ${TAGS_ARGS} \
  --region "${REGION}" \
  --no-fail-on-empty-changeset

echo ""
echo "▶ SSM Parameters written:"
echo "  /dns/hosted-zone-id"
echo "  /dns/domain-name"
echo ""
echo "▶ App repos can read them with:"
echo "  aws ssm get-parameter --name /dns/hosted-zone-id --query Parameter.Value --output text"
echo "  aws ssm get-parameter --name /dns/domain-name    --query Parameter.Value --output text"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅  DNS config ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
