# CI/CD Setup Guide

Everything required to wire the GitHub Actions workflows to Azure and Databricks.

---

## Overview

```
Pull Request  →  ci.yml   →  validate + security scan + plan (all 3 envs)
                             plan output posted as PR comment

Merge to main →  cd.yml   →  apply dev  (automatic)
                         →  apply uat  (automatic, after dev)
                         →  apply prod (manual approval gate)
```

---

## Step 1 – Azure OIDC federated credential

The workflows authenticate to Azure without storing a client secret. Instead,
GitHub requests a short-lived OIDC token that Azure trusts for one run only.

### 1a – Create (or reuse) the Terraform service principal

```bash
az ad sp create-for-rbac \
  --name "sp-databricks-terraform" \
  --role "Owner" \
  --scopes "/subscriptions/<HUB_SUBSCRIPTION_ID>"

# Capture the output – you need appId, tenant, and the SP's object ID
az ad sp show --id <appId> --query id -o tsv   # → object ID
```

### 1b – Add federated credentials (one per branch/environment)

```bash
APP_ID="<appId from above>"

# For the main branch (CD apply)
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:mrsyte/DatabricksSetup:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# For pull requests (CI plan)
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-prs",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:mrsyte/DatabricksSetup:pull_request",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# For the prod GitHub Environment (manual deploy target)
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-env-prod",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:mrsyte/DatabricksSetup:environment:prod",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

---

## Step 2 – GitHub Environments

Create three environments in **Settings → Environments**:

| Environment | Protection rules |
|---|---|
| `dev` | None (auto-deploy) |
| `uat` | None (auto-deploy after dev) |
| `prod` | **Required reviewers** – add the platform engineering team |

For `prod`, also set a **wait timer** of 5 minutes to allow last-second cancellation.

---

## Step 3 – GitHub Secrets

Set the following secrets. Each secret can be scoped to the relevant Environment
or set at the repository level if all environments share the same SP.

Navigate to: **Settings → Secrets and variables → Actions**

### Repository-level secrets (shared across all environments)

| Secret name | Value | How to get it |
|---|---|---|
| `AZURE_CLIENT_ID` | SP application (client) ID | `az ad sp show --id <name> --query appId -o tsv` |
| `AZURE_TENANT_ID` | Azure AD tenant ID | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | Hub subscription ID | `az account show --query id -o tsv` |
| `DATABRICKS_ACCOUNT_ID` | Databricks account ID | accounts.azuredatabricks.net → Settings → General |
| `DATABRICKS_ADMIN_SP_CLIENT_ID` | SP client ID (same SP or a dedicated one) | same as `AZURE_CLIENT_ID` if using one SP |
| `DATABRICKS_ADMIN_SP_OBJECT_ID` | SP object ID in Azure AD | `az ad sp show --id <appId> --query id -o tsv` |
| `DATABRICKS_ADMIN_SP_CLIENT_SECRET` | SP client secret | generated at SP creation; rotate every 90 days |

> **Note on `DATABRICKS_ADMIN_SP_CLIENT_SECRET`**: OIDC covers the `azurerm`
> provider. The `databricks` workspace provider also needs a credential to reach
> the workspace API. Until federated auth is fully supported by the Databricks
> Terraform provider, supply this secret. Rotate it via:
> `az ad app credential reset --id <appId>`

### Adding secrets via CLI (faster than the UI)

```bash
REPO="mrsyte/DatabricksSetup"

gh secret set AZURE_CLIENT_ID           --repo "$REPO" --body "<value>"
gh secret set AZURE_TENANT_ID           --repo "$REPO" --body "<value>"
gh secret set AZURE_SUBSCRIPTION_ID     --repo "$REPO" --body "<value>"
gh secret set DATABRICKS_ACCOUNT_ID     --repo "$REPO" --body "<value>"
gh secret set DATABRICKS_ADMIN_SP_CLIENT_ID    --repo "$REPO" --body "<value>"
gh secret set DATABRICKS_ADMIN_SP_OBJECT_ID    --repo "$REPO" --body "<value>"
gh secret set DATABRICKS_ADMIN_SP_CLIENT_SECRET --repo "$REPO" --body "<value>"
```

---

## Step 4 – GitHub Variables (non-secret)

Variables are visible in workflow logs. Use them for the Terraform backend
storage account name (not a secret, just a resource name).

Navigate to: **Settings → Secrets and variables → Actions → Variables tab**

| Variable name | Value | Notes |
|---|---|---|
| `TF_BACKEND_RG` | `rg-tfstate-prod` | From `bootstrap/main.tf` output `resource_group_name` |
| `TF_BACKEND_SA` | `sttfstateprodXXXXXX` | From `bootstrap/main.tf` output `storage_account_name` |

```bash
REPO="mrsyte/DatabricksSetup"

gh variable set TF_BACKEND_RG --repo "$REPO" --body "rg-tfstate-prod"
gh variable set TF_BACKEND_SA --repo "$REPO" --body "sttfstateprodXXXXXX"
```

---

## Step 5 – Update environment tfvars

Replace the placeholder values in each file with your real values:

```
environments/dev/terraform.tfvars
environments/uat/terraform.tfvars
environments/prod/terraform.tfvars
```

Fields to fill in:

| Field | Value | How to get it |
|---|---|---|
| `hub_subscription_id` | Azure subscription ID | `az account show --query id -o tsv` |
| `tenant_id` | Azure AD tenant ID | `az account show --query tenantId -o tsv` |
| `databricks_admins_group_object_id` | Entra group OID | `az ad group show --group "databricks-workspace-admins" --query id -o tsv` |
| `owner` | Team email alias | Your data platform team alias |
| `cost_center` | Billing code | From your finance team |

> **Do not** put `databricks_account_id`, `databricks_admin_sp_client_id`,
> or `databricks_admin_sp_object_id` in these files — they are injected via
> `TF_VAR_*` GitHub Secrets automatically by the workflow.

---

## Step 6 – Checkov exceptions

If legitimate resources trigger Checkov findings (e.g. a VPN Gateway SKU
that Checkov flags as low), add exceptions to `.checkov.yaml`:

```yaml
# .checkov.yaml
skip-check:
  - CKV_AZURE_XXXX   # reason: <justification>
```

Keep the list minimal and documented.

---

## Complete secret / variable reference

```
GitHub Secrets (Settings → Secrets → Actions)
├── AZURE_CLIENT_ID                      ← SP appId (OIDC, no secret needed for azurerm)
├── AZURE_TENANT_ID                      ← Azure AD tenant
├── AZURE_SUBSCRIPTION_ID                ← Hub subscription
├── DATABRICKS_ACCOUNT_ID                ← Databricks account GUID
├── DATABRICKS_ADMIN_SP_CLIENT_ID        ← SP appId for databricks provider
├── DATABRICKS_ADMIN_SP_OBJECT_ID        ← SP object ID for RBAC assignments
└── DATABRICKS_ADMIN_SP_CLIENT_SECRET    ← SP secret for databricks workspace provider

GitHub Variables (Settings → Secrets → Variables tab)
├── TF_BACKEND_RG    ← resource group of TF state storage account
└── TF_BACKEND_SA    ← storage account name for TF state
```

---

## Workflow behaviour reference

### On a pull request

1. `validate` job runs immediately: YAML check, `terraform fmt`, `terraform validate`
2. `security` job runs Checkov – fails PR if HIGH/CRITICAL findings exist
3. `plan` job runs for each of `[dev, uat, prod]` in parallel
4. Each plan output is posted (or updated) as a PR comment
5. Plans are also uploaded as artifacts (5-day retention) for audit

### On merge to `main`

1. `validate` re-runs as a gate
2. `deploy-dev` applies automatically
3. `deploy-uat` applies automatically after dev succeeds
4. `deploy-prod` waits for manual approval, then applies

### Manual re-apply (drift correction)

```
Actions → CD – Apply → Run workflow
  environment: prod
  dry_run: false
```

### Plan-only run (no apply)

```
Actions → CD – Apply → Run workflow
  environment: prod
  dry_run: true
```

---

## Rotating the SP client secret

```bash
# Generate a new secret (valid for 1 year)
az ad app credential reset \
  --id "<AZURE_CLIENT_ID>" \
  --years 1 \
  --query password -o tsv

# Update the GitHub secret
gh secret set DATABRICKS_ADMIN_SP_CLIENT_SECRET \
  --repo "mrsyte/DatabricksSetup" \
  --body "<new-secret>"
```

Set a calendar reminder to rotate every 90 days.
