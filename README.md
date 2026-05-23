# webapp-environment-setup

Reusable AWS infrastructure-as-code for web application environments.
Deploy once per environment (`dev`, `staging`, `production`); all stacks
share the same templates and are namespaced by `{AppName}-{Env}`.

---

## Repository layout

```
cf/
  network.yml        CloudFormation — VPC, subnets, SGs
  database.yml       CloudFormation — Aurora PostgreSQL Serverless v2

bin/
  deploy-network.sh  Deploy / update the network stack
  deploy-database.sh Deploy / update the database stack
  sync-ssm-to-github.sh  Push AWS SSM params → GitHub secrets/variables
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI v2 | `brew install awscli` |
| Authenticated AWS session | `aws configure` or assume a role |
| `gh` CLI (for SSM→GitHub sync) | `brew install gh && gh auth login` |

---

## Stack 1 — Network (`cf/network.yml`)

### What it creates

| Resource | Detail |
|----------|--------|
| VPC | `/16` CIDR, DNS enabled |
| Public subnets × 2 | `10.0.0/24`, `10.0.1/24` — ALB, NAT GW |
| Private subnets × 2 | `10.0.10/24`, `10.0.11/24` — app servers, ECS, Lambda |
| Isolated subnets × 2 | `10.0.20/24`, `10.0.21/24` — Aurora (no internet route) |
| Internet Gateway | Attached to VPC |
| NAT Gateway | Single, in AZ-1 public subnet (cost-optimised) |
| Route tables | Public → IGW · Private → NAT GW · Isolated → local only |
| Security Groups | `alb-sg` · `app-sg` · `db-sg` |

All subnet IDs, VPC ID, and Security Group IDs are **exported** so the
database stack (and future app stacks) can import them by name.

### Deploy

```bash
./bin/deploy-network.sh --env dev

# Full options
./bin/deploy-network.sh \
  --env        staging \
  --app-name   webapp \
  --region     ap-southeast-2 \
  --vpc-cidr   10.0.0.0/16

# Validate without deploying
./bin/deploy-network.sh --env dev --dry-run
```

---

## Stack 2 — Database (`cf/database.yml`)

> **Prerequisite:** the network stack for the same `--env` must be deployed first.

### What it creates

| Resource | Detail |
|----------|--------|
| Aurora PostgreSQL Serverless v2 | Writer-only instance (`db.serverless`) |
| DB Subnet Group | Spans both isolated subnets |
| DB Cluster Parameter Group | SSL forced · UTC timezone · slow query log (>1 s) |
| Secrets Manager — master secret | `/{app}/{env}/database/master` — auto-rotates every 30 days |
| Secrets Manager — app secret | `/{app}/{env}/database/app` — static connection envelope |
| SSM Parameters | Endpoint, port, DB name, secret ARNs |
| Performance Insights | 7-day retention |

### Secrets Manager structure

**Master secret** — `/{AppName}/{Env}/database/master`

Populated automatically by the `SecretTargetAttachment` + AWS rotation Lambda:

```json
{
  "username": "dbadmin",
  "password": "<generated>",
  "host":     "<cluster-endpoint>",
  "port":     "5432",
  "dbname":   "appdb",
  "engine":   "postgres"
}
```

**App secret** — `/{AppName}/{Env}/database/app`

Static envelope your application code can reference for non-credential
connection metadata (host/password fields are in the master secret):

```json
{
  "engine":   "postgres",
  "dbname":   "appdb",
  "username": "dbadmin",
  "port":     "5432"
}
```

### Fetching credentials in your application

**AWS SDK (Python / boto3):**

```python
import boto3, json

sm = boto3.client("secretsmanager", region_name="ap-southeast-2")
secret = json.loads(
    sm.get_secret_value(SecretId="/webapp/production/database/master")["SecretString"]
)
conn_str = (
    f"postgresql://{secret['username']}:{secret['password']}"
    f"@{secret['host']}:{secret['port']}/{secret['dbname']}"
)
```

**AWS SDK (Node.js):**

```js
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const client = new SecretsManagerClient({ region: "ap-southeast-2" });
const { SecretString } = await client.send(
  new GetSecretValueCommand({ SecretId: "/webapp/production/database/master" })
);
const { username, password, host, port, dbname } = JSON.parse(SecretString);
```

**CLI (quick check):**

```bash
aws secretsmanager get-secret-value \
  --secret-id /webapp/dev/database/master \
  --region ap-southeast-2 \
  --query SecretString --output text | python3 -m json.tool
```

### Deploy

```bash
./bin/deploy-database.sh --env dev

# Full options
./bin/deploy-database.sh \
  --env                 staging \
  --app-name            webapp \
  --region              ap-southeast-2 \
  --db-name             appdb \
  --master-username     dbadmin \
  --min-capacity        0.5 \
  --max-capacity        8 \
  --backup-days         14 \
  --deletion-protection      # recommended for production

# Validate without deploying
./bin/deploy-database.sh --env dev --dry-run
```

---

## Deploying a full environment end-to-end

```bash
# 1. Network (2–3 min)
./bin/deploy-network.sh --env production --deletion-protection

# 2. Database (5–10 min)
./bin/deploy-database.sh --env production --deletion-protection \
  --backup-days 14 --max-capacity 16
```

---

## SSM → GitHub secrets sync

Pushes AWS credentials stored in SSM Parameter Store into a GitHub
repository's Actions secrets/variables so CI pipelines can deploy.

```bash
# Authenticate gh CLI first (one-time)
gh auth login

# Sync to repo-level secrets
./bin/sync-ssm-to-github.sh --github-repo your-org/your-repo

# Sync into a specific GitHub Environment
./bin/sync-ssm-to-github.sh --github-repo your-org/your-repo --env production
```

SSM parameters read:

| SSM path | GitHub destination | Type |
|----------|--------------------|------|
| `/github-actions/aws-access-key-id` | `AWS_ACCESS_KEY_ID` | Secret |
| `/github-actions/aws-secret-access-key` | `AWS_SECRET_ACCESS_KEY` | Secret |
| `/github-actions/aws-account-id` | `AWS_ACCOUNT_ID` | Secret |
| `/github-actions/aws-region` | `AWS_REGION` | Variable |

---

## Resource naming convention

All resources follow: `{AppName}-{Env}-{resource-type}`

Examples:
- `webapp-production-vpc`
- `webapp-dev-aurora-cluster`
- `/webapp/staging/database/master`

CloudFormation exports follow: `{AppName}-{Env}-{ExportKey}`

Examples:
- `webapp-production-VpcId`
- `webapp-dev-DatabaseSecurityGroupId`

---

## Security notes

- Aurora sits in **isolated subnets** — no internet route in or out.
- Only the `app-sg` Security Group can reach the database on port 5432.
- All data at rest is **encrypted** (`StorageEncrypted: true`).
- All connections require **SSL** (`rds.force_ssl: 1`).
- Master password **auto-rotates every 30 days** via Secrets Manager.
- Deletion protection is off by default for dev; pass `--deletion-protection` for production.
