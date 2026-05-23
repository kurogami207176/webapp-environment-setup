# webapp-environment-setup

Reusable AWS infrastructure-as-code for web application environments.
Deploy once per environment (`dev`, `staging`, `production`); all stacks
share the same templates and are namespaced by `{AppName}-{Env}`.

---

## Repository layout

```
cf/
  iam-github-actions-user.yml   CloudFormation — IAM user + policies for CI/CD
  network.yml                   CloudFormation — VPC, subnets, SGs
  database.yml                  CloudFormation — Aurora PostgreSQL Serverless v2
  tags.json                     Shared tags applied to every stack
  params/
    network.staging.json        Environment-specific parameter values
    network.production.json
    database.staging.json
    database.production.json

bin/
  deploy-iam-github-actions-user.sh    ⚠ Manual — deploy IAM user (once per account)
  create-github-actions-credentials.sh ⚠ Manual — create access keys → GitHub secrets
  deploy-network.sh                    Deploy / update the network stack
  deploy-database.sh                   Deploy / update the database stack
  sync-ssm-to-github.sh               Push AWS SSM params → GitHub secrets/variables
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| AWS CLI v2 | `brew install awscli` |
| Authenticated AWS session | `aws configure` or assume a role |
| `gh` CLI | `brew install gh && gh auth login` |

---

## ⚠ Stack 0 — IAM GitHub Actions User (`cf/iam-github-actions-user.yml`)

> **This is a one-time, manual step — do not add it to the CI pipeline.**
> Run this once per AWS account before setting up any other pipeline.

### What it creates

| Resource | Detail |
|----------|--------|
| IAM User | `github-actions-webapp` |
| `GitHubActionsWebappPolicy` | ECR (`webapp-*` repos), CloudFormation (`webapp-*` stacks), IAM (`webapp-*` roles + OIDC provider), App Runner, DynamoDB (`webapp-*` tables) |
| `GitHubActionsWebappNetworkPolicy` | EC2/VPC, ELB, ECS, CloudWatch Logs, SSM parameters |

All policies are least-privilege — resource ARNs are scoped to `webapp-*`
wherever AWS supports resource-level permissions.

### Step 1 — Deploy the IAM user

```bash
./bin/deploy-iam-github-actions-user.sh

# Override defaults if needed
./bin/deploy-iam-github-actions-user.sh \
  --app-name webapp \
  --region   ap-southeast-2 \
  --username github-actions-webapp

# Validate only
./bin/deploy-iam-github-actions-user.sh --dry-run
```

### Step 2 — Create access keys and push to GitHub

```bash
./bin/create-github-actions-credentials.sh --github-repo your-org/your-repo

# Push into a specific GitHub Environment instead of repo-level
./bin/create-github-actions-credentials.sh \
  --github-repo your-org/your-repo \
  --github-env  production
```

This script will:
1. Check how many access keys the user already has (AWS limit: 2)
2. Prompt to delete the oldest key if at limit
3. Create a new access key
4. Push the following directly to GitHub:

| GitHub destination | Value | Type |
|--------------------|-------|------|
| `AWS_ACCESS_KEY_ID` | New key ID | Secret |
| `AWS_SECRET_ACCESS_KEY` | New secret | Secret |
| `AWS_ACCOUNT_ID` | Current account ID | Secret |
| `AWS_REGION` | Region | Variable |

5. Store the key ID (not the secret) in SSM at `/github-actions/access-key-id` for audit/rotation tracking

> **⚠ The secret access key is never stored anywhere after this script runs.**
> If it is lost, delete the key and run the script again.

### Rotating credentials

```bash
# Run the credentials script again — it will prompt to remove the old key
./bin/create-github-actions-credentials.sh --github-repo your-org/your-repo
```

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

All subnet IDs, VPC ID, and Security Group IDs are exported as both
**CloudFormation exports** (for stacks in the same account) and
**SSM Parameters** (for other repos / pipelines):

```
/{AppName}/{Env}/network/vpc-id
/{AppName}/{Env}/network/vpc-cidr
/{AppName}/{Env}/network/public-subnet-ids
/{AppName}/{Env}/network/private-subnet-ids
/{AppName}/{Env}/network/isolated-subnet-ids
/{AppName}/{Env}/network/alb-sg-id
/{AppName}/{Env}/network/app-sg-id
/{AppName}/{Env}/network/db-sg-id
```

### Environment parameters (`cf/params/network.<env>.json`)

Edit the relevant file to change VPC CIDRs. Staging and production use
different `/16` blocks (`10.0.x.x` and `10.1.x.x`) so they never overlap.

### Deploy

```bash
./bin/deploy-network.sh --env staging
./bin/deploy-network.sh --env production

# Validate without deploying
./bin/deploy-network.sh --env staging --dry-run
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

### Environment parameters (`cf/params/database.<env>.json`)

| Setting | Staging | Production |
|---------|---------|------------|
| Min capacity | 0.5 ACUs | 0.5 ACUs |
| Max capacity | 4 ACUs | 4 ACUs |
| Backup retention | 7 days | 14 days |
| Deletion protection | off | on |

Edit `cf/params/database.<env>.json` to change any of these — no pipeline
or script changes required.

### Secrets Manager structure

**Master secret** — `/{AppName}/{Env}/database/master`

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

```json
{
  "engine":   "postgres",
  "dbname":   "appdb",
  "username": "dbadmin",
  "port":     "5432"
}
```

### Fetching credentials in your application

**Python / boto3:**

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

**Node.js:**

```js
import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";

const client = new SecretsManagerClient({ region: "ap-southeast-2" });
const { SecretString } = await client.send(
  new GetSecretValueCommand({ SecretId: "/webapp/production/database/master" })
);
const { username, password, host, port, dbname } = JSON.parse(SecretString);
```

**CLI:**

```bash
aws secretsmanager get-secret-value \
  --secret-id /webapp/staging/database/master \
  --region ap-southeast-2 \
  --query SecretString --output text | python3 -m json.tool
```

### Deploy

```bash
./bin/deploy-database.sh --env staging
./bin/deploy-database.sh --env production

# Validate without deploying
./bin/deploy-database.sh --env staging --dry-run
```

---

## Deploying a full environment end-to-end

```bash
# 1. IAM user — once per account, manual
./bin/deploy-iam-github-actions-user.sh
./bin/create-github-actions-credentials.sh --github-repo your-org/your-repo

# 2. Network (~2–3 min)
./bin/deploy-network.sh --env staging

# 3. Database (~5–10 min)
./bin/deploy-database.sh --env staging
```

---

## Tags (`cf/tags.json`)

All stacks pass a shared set of tags to every resource via
`aws cloudformation deploy --tags`. Edit `cf/tags.json` to add or change tags
globally — no template or script changes needed.

```json
[
  { "Key": "git_repo",   "Value": "https://github.com/kurogami207176/webapp-environment-setup" },
  { "Key": "managed_by", "Value": "cloudformation" },
  { "Key": "team",       "Value": "platform" }
]
```

---

## Resource naming convention

| Pattern | Example |
|---------|---------|
| AWS resources | `{AppName}-{Env}-{type}` → `webapp-production-vpc` |
| CloudFormation stacks | `{AppName}-{Env}-{stack}` → `webapp-staging-network` |
| CloudFormation exports | `{AppName}-{Env}-{Key}` → `webapp-production-VpcId` |
| SSM parameters | `/{AppName}/{Env}/{path}` → `/webapp/staging/network/vpc-id` |
| Secrets Manager | `/{AppName}/{Env}/{path}` → `/webapp/production/database/master` |

---

## Security notes

- Aurora sits in **isolated subnets** — no internet route in or out.
- Only the `app-sg` Security Group can reach the database on port 5432.
- All data at rest is **encrypted** (`StorageEncrypted: true`).
- All connections require **SSL** (`rds.force_ssl: 1`).
- Master password **auto-rotates every 30 days** via Secrets Manager.
- IAM policies are scoped to `webapp-*` resources wherever AWS supports it.
- Access key secret is never stored after creation — rotate by re-running the credentials script.
