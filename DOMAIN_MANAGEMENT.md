# Domain Management Guide

## Architecture overview

Each domain is a fully independent unit:

| Resource | Per domain |
|---|---|
| Azure spoke VNet (data services + ADB VNet injection) | ✓ |
| Databricks workspace (Premium, NPIP, private link) | ✓ |
| ADLS Gen2 storage account | ✓ |
| Storage containers | `dev`, `test`, `prod`, `checkpoints` |
| Azure Key Vault | ✓ |
| Unity Catalog catalogs | `{domain}_dev`, `{domain}_test`, `{domain}_prod` |
| Unity Catalog schemas per catalog | `raw`, `curated`, `published` + subject areas |

All domains share: Azure Firewall, VPN Gateway, DNS Private Resolver, Log Analytics, and the Unity Catalog metastore.

---

## How domain ownership works

Domain configuration lives entirely in **`domains.yaml`** — the single source of truth.
Terraform reads this file and propagates every field automatically:

| `domains.yaml` field | Where it lands |
|---|---|
| `owner.email` | Azure resource tags (`domain_owner`), all 3 catalog and schema `properties.owner`, cluster tag `owner` |
| `owner.escalation` | Azure resource tags (`escalation`) |
| `owner.teams_channel` | Azure resource tags (`teams_channel`), catalog `properties.teams_channel` |
| `description` | Unity Catalog catalog comment (all 3 catalogs) |
| `subject_areas[].owner` | Schema-level `properties.owner` across all 3 catalogs |
| `access.*_group_id` | Azure RBAC role assignments + Databricks Unity Catalog grants |
| `network.address_space` | Spoke VNet CIDR (set at creation, **do not change**) |

**To update any of this, edit `domains.yaml` and open a PR. No `.tf` files need to change.**

---

## Environment catalogs

Each domain workspace contains three Unity Catalog catalogs:

| Catalog | Purpose | Engineer access |
|---|---|---|
| `{domain}_dev` | Development and experimentation | `ALL_PRIVILEGES` |
| `{domain}_test` | Integration testing, validation | `ALL_PRIVILEGES` |
| `{domain}_prod` | Production data products | `USE_CATALOG`, `CREATE_SCHEMA`, `CREATE_TABLE`, `CREATE_FUNCTION` |

Domain owners have `ALL_PRIVILEGES` on all three catalogs. Viewers have `USE_CATALOG` (read-only after schema-level grants).

Each catalog has the same schema structure:

```
{domain}_dev
  ├── raw            ← ingestion zone
  ├── curated        ← silver / cleansed
  ├── published      ← gold / data products
  └── <subject_area> ← per subject_areas[] entry
```

Data written to the `dev` container in ADLS backs `{domain}_dev`; `test` backs `{domain}_test`; `prod` backs `{domain}_prod`.

---

## Updating a domain owner

1. Open `domains.yaml` in your editor (or directly on GitHub).
2. Find the domain block (e.g. `finance:`).
3. Update `owner.email` (and optionally `owner.escalation`, `owner.teams_channel`).
4. Validate locally:
   ```bash
   python scripts/validate_domains.py
   ```
5. Open a pull request. Title convention: `chore(domains): update finance owner`.
6. CI runs `terraform plan` — expect tag updates on Azure resources and
   `properties.owner` changes on all Unity Catalog catalogs and schemas.
7. Merge. CD applies automatically.

**No infrastructure is recreated.** Only tags and catalog properties are updated in-place.

---

## Adding a new domain

### Prerequisites

Before editing `domains.yaml` you need three things from your Azure AD admin:

1. **Three Entra groups** created and their Object IDs noted:
   ```
   databricks-<domain>-owners
   databricks-<domain>-engineers
   databricks-<domain>-viewers
   ```
   Creation (repeat for each role):
   ```bash
   az ad group create \
     --display-name "databricks-<domain>-owners" \
     --mail-nickname "databricks-<domain>-owners"

   az ad group show --group "databricks-<domain>-owners" --query id -o tsv
   ```

2. **A non-overlapping CIDR block** (minimum `/20`, recommend `/16`) for the domain spoke VNet.

   The spoke VNet hosts four subnets — confirm your CIDR fits all of them:

   | Subnet | Size | Purpose |
   |---|---|---|
   | `snet-private-endpoints` | /24 | Storage, KV, workspace private endpoints |
   | `snet-data-services` | /24 | Data service VMs |
   | `snet-adb-public` | /25 | ADB host (worker NIC) subnet |
   | `snet-adb-private` | /25 | ADB container subnet |

   Current allocations:
   | Domain | CIDR |
   |---|---|
   | hub VNet | 10.0.0.0/16 |
   | finance | 10.10.0.0/16 |
   | marketing | 10.20.0.0/16 |
   | operations | 10.30.0.0/16 |
   | hr | 10.40.0.0/16 |
   | supply_chain | 10.50.0.0/16 |

   **Next available:** 10.60.0.0/16, 10.70.0.0/16, etc.

3. **Owner contact information**: team alias email, escalation email, Microsoft Teams channel (format: `"Team Name/Channel Name"`).

### Step-by-step

**Step 1 — Add the domain block to `domains.yaml`**

```yaml
  # Example: adding "customer_success" domain
  customer_success:
    description: "Customer success domain: onboarding, health scores, churn, NPS"
    owner:
      email:         "cs-data-team@contoso.com"
      escalation:    "vp-cs@contoso.com"
      teams_channel: "Data Platform/Customer Success"
    network:
      address_space: "10.60.0.0/16"   # next available block
    access:
      owners_group_id:    "66666666-0000-0000-0000-000000000001"   # replace with real OIDs
      engineers_group_id: "66666666-0000-0000-0000-000000000002"
      viewers_group_id:   "66666666-0000-0000-0000-000000000003"
    subject_areas:
      - name:        onboarding
        description: "Time-to-value, activation milestones, onboarding completion"
        owner:       "cs-onboarding@contoso.com"
      - name:        health_scores
        description: "Product usage signals, CSAT, engagement scores"
        owner:       "cs-analytics@contoso.com"
      - name:        churn
        description: "Churn risk models, leading indicators, save plays"
        owner:       "cs-analytics@contoso.com"
```

Domain name rules:
- Lowercase letters, digits and underscores only
- Must start with a letter
- 2–31 characters
- Must be unique

**Step 2 — Validate**

```bash
python scripts/validate_domains.py
```

Fix any reported errors before proceeding.

**Step 3 — Open a pull request**

Title convention: `feat(domains): add customer_success domain`

Include in the PR description:
- Business justification / data product owner sign-off
- Confirmed CIDR is non-overlapping (validation script checks this)
- Entra group Object IDs reviewed by Azure AD admin

**Step 4 — Review `terraform plan` output in CI**

Expect to see new resources only — no changes to existing domains:

```
# Azure infrastructure
module.domain_spoke["customer_success"].azurerm_resource_group.spoke              will be created
module.domain_spoke["customer_success"].azurerm_virtual_network.spoke             will be created
module.domain_spoke["customer_success"].azurerm_subnet.adb_public                 will be created
module.domain_spoke["customer_success"].azurerm_subnet.adb_private                will be created
module.domain_spoke["customer_success"].azurerm_databricks_workspace.domain       will be created
module.domain_spoke["customer_success"].azurerm_storage_account.domain            will be created
module.domain_spoke["customer_success"].azurerm_storage_container.env["dev"]      will be created
module.domain_spoke["customer_success"].azurerm_storage_container.env["test"]     will be created
module.domain_spoke["customer_success"].azurerm_storage_container.env["prod"]     will be created
module.domain_spoke["customer_success"].azurerm_key_vault.domain                  will be created

# Unity Catalog (three catalogs × landing zones)
module.unity_catalog.databricks_metastore_assignment.domain["customer_success"]            will be created
module.unity_catalog.databricks_catalog.domain_env["customer_success__dev"]               will be created
module.unity_catalog.databricks_catalog.domain_env["customer_success__test"]              will be created
module.unity_catalog.databricks_catalog.domain_env["customer_success__prod"]              will be created
module.unity_catalog.databricks_schema.landing_zone["customer_success__dev__raw"]         will be created
...
module.unity_catalog.databricks_schema.subject_area["customer_success__dev__onboarding"]  will be created
...
```

**Step 5 — Merge**

CD applies dev → uat → prod (prod requires manual approval). The new domain is live within ~10 minutes.

**Step 6 — Bootstrap the workspace** (first time only)

After `terraform apply` completes, run the bootstrap script from within the VPN or hub VNet to configure the workspace's cluster policy, security settings, and Key Vault secret scope:

```bash
# From a machine connected via VPN (or a VM in the hub VNet):
terraform output -json domain_workspace_urls > /tmp/workspaces.json
export KEYVAULT_IDS_JSON="$(terraform output -json domain_keyvault_uris)"

DATABRICKS_CLIENT_ID=<sp-client-id> \
DATABRICKS_CLIENT_SECRET=<sp-secret> \
AZURE_TENANT_ID=<tenant-id> \
  python scripts/workspace_bootstrap.py /tmp/workspaces.json
```

The script is idempotent — running it again on an already-bootstrapped workspace is safe.

---

## Adding a subject area to an existing domain

Subject areas are schemas in Unity Catalog. Adding one creates the schema in **all three catalogs** (`dev`, `test`, `prod`) for that domain. **No networking or storage changes occur.**

**Step 1 — Add the entry under the domain in `domains.yaml`**

```yaml
  finance:
    subject_areas:
      # ... existing entries ...
      - name:        accounts_receivable        # ← new
        description: "Customer invoices, collections, DSO"
        owner:       "ar-team@contoso.com"
```

Subject area name rules: same as domain names (lowercase, underscore, 2–51 chars).

**Step 2 — Validate and open a PR**

```bash
python scripts/validate_domains.py
```

PR title convention: `feat(domains): add accounts_receivable to finance`

**Step 3 — Review plan and merge**

Three schemas are created (one per environment), no changes to existing schemas:

```
module.unity_catalog.databricks_schema.subject_area["finance__dev__accounts_receivable"]   will be created
module.unity_catalog.databricks_schema.subject_area["finance__test__accounts_receivable"]  will be created
module.unity_catalog.databricks_schema.subject_area["finance__prod__accounts_receivable"]  will be created
```

---

## Removing a subject area

Subject area removal deletes the schema from Unity Catalog metadata only.
Underlying data in ADLS is **not deleted**.

1. Confirm all three environment schemas are empty (no tables) or data has been migrated.
2. Remove the entry from `domains.yaml`.
3. Open a PR — plan shows three `databricks_schema ... will be destroyed`.
4. Merge only after data owner sign-off.

---

## Removing a domain

Domain removal destroys the workspace, VNet, storage, and Key Vault. It is **irreversible for networking resources**. Follow this checklist:

- [ ] All data products using this domain have been decommissioned or migrated (all 3 envs)
- [ ] No active jobs, pipelines or notebooks reference any of the three catalogs
- [ ] Storage data archived or deleted per retention policy (dev, test, and prod containers)
- [ ] Domain workspace confirmed idle (no running clusters)
- [ ] Domain data owner and platform team have both signed off

Steps:
1. Remove the domain block from `domains.yaml`.
2. Open a PR labelled `breaking: decommission <domain>`.
3. Terraform plan shows destruction of: workspace, spoke VNet, storage account, Key Vault, three catalogs, and all schemas.
4. Require two approvals (domain owner + platform engineer).
5. After merge, storage containers are soft-deleted for 30 days (blob versioning).
   Permanent deletion requires a separate `terraform apply -target` with the purge policy lifted.

---

## Rotating group ownership (Entra group changes)

If an Entra group is recreated with a new Object ID:

1. Update the `access.*_group_id` field in `domains.yaml` with the new Object ID.
2. Open a PR — plan shows role assignment and Databricks grant updates across all three catalogs.
3. Old group loses access on apply; new group gains access immediately.

---

## Quick reference

| Task | File to edit | Terraform impact |
|---|---|---|
| Update domain owner / Teams channel | `domains.yaml` | Tag + catalog property updates (fast, in-place) |
| Add subject area | `domains.yaml` | 3 new schemas (dev + test + prod) |
| Remove subject area | `domains.yaml` | 3 schemas destroyed (data not deleted) |
| Add new domain | `domains.yaml` + create 3 Entra groups | New workspace, VNet, storage, KV, 3 catalogs created |
| Remove domain | `domains.yaml` | Destructive — workspace + all infra destroyed |
| Change Entra group | `domains.yaml` | RBAC and grants updated across all 3 catalogs |
| Change CIDR | ⚠️ **Not supported after first apply** | Would destroy/recreate VNet and workspace |
| Change infrastructure config | `terraform.tfvars` | Varies |
