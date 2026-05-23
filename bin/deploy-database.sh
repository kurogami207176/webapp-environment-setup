#!/usr/bin/env bash
# bin/deploy-database.sh
# ---------------------------------------------------------------------------
# Deploys (or updates) the Aurora PostgreSQL Serverless v2 CloudFormation
# stack. The network stack MUST already exist before running this.
#
# Usage:
#   ./bin/deploy-database.sh --env <dev|staging|production> [options]
#
# Options:
#   --env              <dev|staging|production>  required
#   --app-name         <name>                    default: webapp
#   --region           <aws-region>              default: ap-southeast-2
#   --db-name          <name>                    default: appdb
#   --master-username  <name>                    default: dbadmin
#   --min-capacity     <acus>                    default: 0.5
#   --max-capacity     <acus>                    default: 4
#   --backup-days      <1-35>                    default: 7
#   --deletion-protection                        enables deletion protection
#   --dry-run                                    validate template only
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
APP_NAME="webapp"
ENV=""
REGION="ap-southeast-2"
DB_NAME="appdb"
MASTER_USERNAME="dbadmin"
MIN_CAPACITY="0.5"
MAX_CAPACITY="4"
BACKUP_DAYS="7"
DELETION_PROTECTION="false"
DRY_RUN=false

CF_DIR="$(cd "$(dirname "$0")/../cf" && pwd)"
TEMPLATE="${CF_DIR}/database.yml"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)                  ENV="$2";              shift 2 ;;
    --app-name)             APP_NAME="$2";         shift 2 ;;
    --region)               REGION="$2";           shift 2 ;;
    --db-name)              DB_NAME="$2";          shift 2 ;;
    --master-username)      MASTER_USERNAME="$2";  shift 2 ;;
    --min-capacity)         MIN_CAPACITY="$2";     shift 2 ;;
    --max-capacity)         MAX_CAPACITY="$2";     shift 2 ;;
    --backup-days)          BACKUP_DAYS="$2";      shift 2 ;;
    --deletion-protection)  DELETION_PROTECTION="true"; shift ;;
    --dry-run)              DRY_RUN=true;          shift   ;;
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
    echo "    Run first: ./bin/deploy-network.sh --env ${ENV} --app-name ${APP_NAME}" >&2
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
echo "  App:          ${APP_NAME}"
echo "  Env:          ${ENV}"
echo "  Stack:        ${STACK_NAME}"
echo "  Region:       ${REGION}"
echo "  DB Name:      ${DB_NAME}"
echo "  Master User:  ${MASTER_USERNAME}"
echo "  Capacity:     ${MIN_CAPACITY}–${MAX_CAPACITY} ACUs"
echo "  Backup Days:  ${BACKUP_DAYS}"
echo "  Del. Protect: ${DELETION_PROTECTION}"
[[ "${DRY_RUN}" == "true" ]] && echo "  Mode:         DRY RUN (validate only)"
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
  --parameter-overrides \
      "AppName=${APP_NAME}" \
      "Env=${ENV}" \
      "DatabaseName=${DB_NAME}" \
      "MasterUsername=${MASTER_USERNAME}" \
      "MinCapacity=${MIN_CAPACITY}" \
      "MaxCapacity=${MAX_CAPACITY}" \
      "BackupRetentionDays=${BACKUP_DAYS}" \
      "DeletionProtection=${DELETION_PROTECTION}" \
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

# ── Show Secrets Manager paths ────────────────────────────────────────────────
echo ""
echo "▶ Secrets Manager entries:"
echo ""
echo "  Master credentials (with auto-rotation):"
echo "    /${APP_NAME}/${ENV}/database/master"
echo ""
echo "  App connection details:"
echo "    /${APP_NAME}/${ENV}/database/app"
echo ""
echo "▶ SSM Parameters (non-sensitive, for scripts/CI):"
echo ""
echo "    /${APP_NAME}/${ENV}/database/endpoint"
echo "    /${APP_NAME}/${ENV}/database/port"
echo "    /${APP_NAME}/${ENV}/database/name"
echo "    /${APP_NAME}/${ENV}/database/master-secret-arn"
echo "    /${APP_NAME}/${ENV}/database/app-secret-arn"

# ── Fetch and display the endpoint ────────────────────────────────────────────
echo ""
echo "▶ Connection info:"
ENDPOINT=$(aws ssm get-parameter \
  --name "/${APP_NAME}/${ENV}/database/endpoint" \
  --region "${REGION}" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "(not yet available)")
PORT=$(aws ssm get-parameter \
  --name "/${APP_NAME}/${ENV}/database/port" \
  --region "${REGION}" \
  --query 'Parameter.Value' \
  --output text 2>/dev/null || echo "5432")

echo ""
echo "  Host:     ${ENDPOINT}"
echo "  Port:     ${PORT}"
echo "  Database: ${DB_NAME}"
echo "  User:     ${MASTER_USERNAME}"
echo "  Password: (stored in Secrets Manager — fetch with command below)"
echo ""
echo "  aws secretsmanager get-secret-value \\"
echo "    --secret-id /${APP_NAME}/${ENV}/database/master \\"
echo "    --region ${REGION} \\"
echo "    --query SecretString --output text | python3 -m json.tool"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅  Database stack ready: ${STACK_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
