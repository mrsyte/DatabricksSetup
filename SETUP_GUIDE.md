# Pre-deployment Setup Guide

Everything that must exist **before** running `terraform init` for the first time.

---

## 1  Azure Tenant prerequisites

### 1.1  Required Azure AD / Entra ID roles

| Who | Role needed | Why |
|-----|-------------|-----|
| Terraform service principal | **Owner** on the hub subscription | Creates VNets, Firewall, Key Vaults, RGs, role assignments |
| Terraform service principal | **Contributor** on any spoke subscriptions (if separate) | Creates spoke resources |
| Terraform service principal | **User Access Administrator** on hub subscription | Creates `azurerm_role_assignment` resources |
| Terraform service principal | **Private DNS Zone Contributor** on hub subscription | Creates and links private DNS zones |

> Tip: Rather than Owner, combine **Contributor + User Access Administrator** for least privilege.

### 1.2  Create the Terraform service principal

```bash
# Sign in as a Global Administrator or Subscription Owner
az login

# Create an SP and capture credentials – store in a secret manager, NOT git
az ad sp create-for-rbac \
  --name "sp-databricks-terraform-prod" \
  --role "Owner" \
  --scopes "/subscriptions/<hub-subscription-id>" \
  --sdk-auth
```

Save the JSON output. You will use it to set environment variables:

```bash
export ARM_CLIENT_ID="<appId>"
export ARM_CLIENT_SECRET="<password>"
export ARM_SUBSCRIPTION_ID="<hub-subscription-id>"
export ARM_TENANT_ID="<tenant>"
```

### 1.3  Register required Azure resource providers

```bash
az provider register --namespace Microsoft.Databricks
az provider register --namespace Microsoft.Network
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Storage
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.Insights
az provider register --namespace Microsoft.Authorization
```

---

## 2  Entra ID groups

Create the following Entra groups **before** running Terraform. Record each group's **Object ID** — these become `owners_group_id`, `engineers_group_id`, `viewers_group_id` in `domains.yaml`.

### 2.1  Platform admin group (metastore admins)

```bash
az ad group create \
  --display-name "databricks-workspace-admins" \
  --mail-nickname "databricks-workspace-admins"

# Note the object ID → databricks_admins_group_object_id in terraform.tfvars
az ad group show --group "databricks-workspace-admins" --query id -o tsv
```

### 2.2  Per-domain groups (repeat for each domain in domains.yaml)

Replace `<DOMAIN>` with the domain key (e.g. `finance`):

```bash
for ROLE in owners engineers viewers; do
  az ad group create \
    --display-name "databricks-<DOMAIN>-${ROLE}" \
    --mail-nickname "databricks-<DOMAIN>-${ROLE}"
  echo "<DOMAIN> ${ROLE}: $(az ad group show --group "databricks-<DOMAIN>-${ROLE}" --query id -o tsv)"
done
```

Paste the Object IDs into the corresponding domain block in `domains.yaml`.

### 2.3  Add the Terraform SP to the admin group

```bash
az ad group member add \
  --group "databricks-workspace-admins" \
  --member-id "<terraform-sp-object-id>"
```

---

## 3  Databricks account setup

### 3.1  About the workspace architecture

Each domain defined in `domains.yaml` gets its own **dedicated Databricks workspace** (Premium SKU, NPIP, private link). Workspace creation is handled automatically by `modules/domain_spoke`. No manual workspace creation is needed.

Within each workspace, Unity Catalog provides three environment catalogs:
- `{domain}_dev` — development
- `{domain}_test` — integration testing
- `{domain}_prod` — production

### 3.2  Link your Azure tenant to a Databricks account

1. Go to [accounts.azuredatabricks.net](https://accounts.azuredatabricks.net)
2. Sign in with the **Global Administrator** of the Azure tenant.
3. If no account exists you will be prompted to create one. Accept the terms.
4. Record the **Account ID** from **Settings → General** → paste into `terraform.tfvars` as `databricks_account_id`.

### 3.3  Grant the Terraform SP Databricks account admin

The SP must be able to create a Unity Catalog metastore and assign it to each workspace.

```bash
# Get the SP's object ID
SP_OID=$(az ad sp show --id "<client-id>" --query id -o tsv)
echo $SP_OID
```

In the Databricks account console:
1. **Settings → Identity and access → Service principals** → **Add service principal**
2. Enter the SP client ID and name, click Add.
3. Click the SP → **Roles** → enable **Account admin**.

Alternatively via the Databricks CLI (requires account admin token):

```bash
databricks account service-principals create \
  --display-name "sp-databricks-terraform-prod" \
  --application-id "<client-id>"

databricks account service-principals update \
  --id <sp-id-returned-above> \
  --roles account_admin
```

### 3.4  Terraform SP authentication to Databricks

The Databricks provider picks up credentials from the same ARM environment variables:

```bash
export ARM_CLIENT_ID="<appId>"
export ARM_CLIENT_SECRET="<password>"
export ARM_TENANT_ID="<tenant>"
```

No extra Databricks-specific variables are needed when using Azure-integrated auth.

---

## 4  Deploy Terraform state storage (bootstrap)

Run the bootstrap once to create the storage account for remote state:

```bash
cd bootstrap

terraform init

terraform apply \
  -var="subscription_id=<hub-subscription-id>" \
  -var="environment=prod" \
  -var="deployer_object_id=$(az ad sp show --id $ARM_CLIENT_ID --query id -o tsv)"
```

Copy the `backend_config_snippet` output and update `versions.tf`:

```hcl
backend "azurerm" {
  resource_group_name  = "rg-tfstate-prod"
  storage_account_name = "sttfstateprodXXXXXX"   # from output
  container_name       = "tfstate"
  key                  = "databricks-hub-spoke.tfstate"
}
```

---

## 5  Main deployment

```bash
cd ..   # back to repo root

# Initialise with remote state
terraform init \
  -backend-config="resource_group_name=rg-tfstate-prod" \
  -backend-config="storage_account_name=sttfstateprodXXXXXX" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=dev/databricks-hub-spoke.tfstate"

# Preview
terraform plan -var-file=environments/dev/terraform.tfvars -out=tfplan

# Apply (all modules in dependency order)
terraform apply tfplan
```

Expected apply time: **40–60 minutes** for a full deployment. The VPN Gateway takes the longest (~30 min); each Databricks workspace adds ~5–8 minutes. With 5 sample domains, plan for approximately 60 minutes on first apply.

---

## 6  Post-deployment: workspace bootstrap

After `terraform apply` completes, run the bootstrap script to configure each domain workspace with security settings, the default cluster policy, and the Key Vault–backed secret scope.

> **Network access required.** Workspace private endpoints are not reachable from the public internet. Run this step from a machine connected via the hub VPN or from a VM inside the hub VNet.

```bash
# Get workspace URLs and Key Vault IDs from Terraform state
terraform output -json domain_workspace_urls > /tmp/workspaces.json
export KEYVAULT_IDS_JSON="$(terraform output -json domain_keyvault_uris)"

# Run the bootstrap (uses the same SP credentials)
DATABRICKS_CLIENT_ID="$ARM_CLIENT_ID" \
DATABRICKS_CLIENT_SECRET="$ARM_CLIENT_SECRET" \
AZURE_TENANT_ID="$ARM_TENANT_ID" \
  python scripts/workspace_bootstrap.py /tmp/workspaces.json
```

The script is **idempotent** — safe to re-run. It configures per workspace:
- Workspace security settings (disable result downloads, enforce token lifetime, etc.)
- Default cluster policy (required tags: `app`, `domain`, `owner`, `cost_center`)
- Key Vault–backed secret scope named after the domain (e.g. `finance`)

---

## 7  Post-deployment: VPN client profile

After the VPN Gateway is provisioned, distribute the VPN client profile to users:

```bash
# Generate the VPN client profile package
VPN_GW_NAME="vpng-adb-$(terraform output -raw environment)-hub"
RG="$(terraform output -raw hub_vnet_id | grep -oP '(?<=resourceGroups/)[^/]+')"

az network vnet-gateway vpn-client generate \
  --name "$VPN_GW_NAME" \
  --resource-group "$RG" \
  --processor-architecture Amd64
```

Distribute the downloaded `.zip` to VPN users. They install the **Azure VPN Client** app and import the profile. Authentication uses their Entra credentials.

---

## 8  Accessing domain workspaces (users on VPN)

Each domain has its own workspace URL. List all workspace URLs:

```bash
terraform output domain_workspace_urls
```

Example output:
```
{
  "finance"      = "https://adb-xxx1.azuredatabricks.net"
  "marketing"    = "https://adb-xxx2.azuredatabricks.net"
  "operations"   = "https://adb-xxx3.azuredatabricks.net"
  ...
}
```

Workspace URLs resolve to private IPs via the `privatelink.azuredatabricks.net` DNS zone. They are unreachable from the public internet — VPN connection is required.

Domain team members are granted access through their Entra group membership (owners / engineers / viewers).

---

## 9  Secret scope usage

Each domain workspace has a Key Vault–backed secret scope named after the domain. From a notebook in the `finance` workspace:

```python
# Read a secret from the domain Key Vault
secret_value = dbutils.secrets.get(scope="finance", key="my-secret-name")

# List available secrets
dbutils.secrets.list("finance")
```

Add secrets to the Key Vault in the domain resource group:

```bash
az keyvault secret set \
  --vault-name "kv-adb-prod-finance-XXXXXX" \
  --name "my-secret-name" \
  --value "super-secret-value"
```

> The secret scope is created by `scripts/workspace_bootstrap.py`. If it is missing, re-run the bootstrap step above.

---

## 10  Adding a new domain

See **[DOMAIN_MANAGEMENT.md](DOMAIN_MANAGEMENT.md)** for the complete step-by-step guide including CIDR allocation table, `domains.yaml` example, expected Terraform plan output, and workspace bootstrap instructions.
