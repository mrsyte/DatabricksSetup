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

Create the following Entra groups **before** running Terraform. Record each group's **Object ID** — these become `owners_group_id`, `engineers_group_id`, `viewers_group_id` in `terraform.tfvars`.

### 2.1  Platform admin group (workspace admins)

```bash
az ad group create \
  --display-name "databricks-workspace-admins" \
  --mail-nickname "databricks-workspace-admins"

# Note the object ID in the output → databricks_admins_group_object_id
az ad group show --group "databricks-workspace-admins" --query id -o tsv
```

### 2.2  Per-domain groups (repeat for each domain)

Replace `<DOMAIN>` with the domain key used in `terraform.tfvars` (e.g. `finance`):

```bash
for ROLE in owners engineers viewers; do
  az ad group create \
    --display-name "databricks-<DOMAIN>-${ROLE}" \
    --mail-nickname "databricks-<DOMAIN>-${ROLE}"
  echo "<DOMAIN> ${ROLE}: $(az ad group show --group "databricks-<DOMAIN>-${ROLE}" --query id -o tsv)"
done
```

Collect the six object IDs (owners / engineers / viewers for each domain) and paste them into `terraform.tfvars`.

### 2.3  Add the Terraform SP to the admin group

```bash
az ad group member add \
  --group "databricks-workspace-admins" \
  --member-id "<terraform-sp-object-id>"
```

---

## 3  Databricks account setup

### 3.1  Enable Azure Databricks Premium

The workspace Terraform creates requires **Premium SKU**. This is set in `modules/databricks_workspace/main.tf` (`sku = "premium"`) — no manual step needed.

### 3.2  Link your Azure tenant to a Databricks account

1. Go to [accounts.azuredatabricks.net](https://accounts.azuredatabricks.net)
2. Sign in with the **Global Administrator** of the Azure tenant.
3. If no account exists you will be prompted to create one. Accept the terms.
4. Record the **Account ID** from **Settings → General** → paste into `terraform.tfvars` as `databricks_account_id`.

### 3.3  Grant the Terraform SP Databricks account admin

The SP must be able to create a Unity Catalog metastore and assign it to the workspace.

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

# Assign account admin role
databricks account service-principals update \
  --id <sp-id-returned-above> \
  --roles account_admin
```

### 3.4  Terraform SP authentication to Databricks

The Databricks provider picks up credentials from the same ARM environment variables used by `azurerm`:

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
terraform init

# Preview
terraform plan -var-file=terraform.tfvars -out=tfplan

# Apply (all modules in dependency order)
terraform apply tfplan
```

Expected apply time: ~25–35 minutes (VPN Gateway creation takes longest).

---

## 6  Post-deployment: VPN client profile

After the VPN Gateway is provisioned:

```bash
# Generate the VPN client profile package
VPN_GW_ID=$(terraform output -raw hub_vnet_id | sed 's|/virtualNetworks/.*||')/providers/Microsoft.Network/virtualNetworkGateways/vpng-adb-prod-hub

az network vnet-gateway vpn-client generate \
  --ids "$VPN_GW_ID" \
  --processor-architecture Amd64
```

Distribute the downloaded `.zip` to VPN users. They install the **Azure VPN Client** app and import the profile. Authentication uses their Entra credentials.

---

## 7  Databricks workspace access (users on VPN)

Once connected to VPN, users reach the workspace at:

```
terraform output workspace_url
```

The workspace URL resolves to a private IP via the `privatelink.azuredatabricks.net` DNS zone. It is unreachable from the public internet.

---

## 8  Secret scope usage

From a Databricks notebook:

```python
# Read a secret from the domain's Key Vault–backed scope
secret_value = dbutils.secrets.get(scope="finance", key="my-secret-name")

# List secrets in a scope
dbutils.secrets.list("finance")
```

Add secrets to the Key Vault in the relevant domain resource group using:

```bash
az keyvault secret set \
  --vault-name "kv-adb-prod-<domain>-XXXXXX" \
  --name "my-secret-name" \
  --value "super-secret-value"
```

---

## 9  Adding a new domain later

1. Add a new entry to `domains` in `terraform.tfvars` with a non-overlapping `address_space`.
2. Create the three Entra groups and add their object IDs.
3. `terraform plan && terraform apply` — only new resources are created; existing ones are unchanged.
