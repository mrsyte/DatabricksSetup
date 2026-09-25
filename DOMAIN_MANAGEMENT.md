# Domain Management Guide

## How domain ownership works

Domain configuration lives entirely in **`domains.yaml`** — the single source of truth.
Terraform reads this file and propagates every field automatically:

| `domains.yaml` field | Where it lands |
|---|---|
| `owner.email` | Azure resource tags (`domain_owner`), Unity Catalog catalog/schema `properties.owner`, cluster tag `owner` |
| `owner.escalation` | Azure resource tags (`escalation`) |
| `owner.teams_channel` | Azure resource tags (`teams_channel`), Unity Catalog catalog `properties.teams_channel` |
| `description` | Unity Catalog catalog comment |
| `subject_areas[].owner` | Schema-level `properties.owner` in Unity Catalog |
| `access.*_group_id` | Azure RBAC role assignments + Databricks Unity Catalog grants |
| `network.address_space` | Spoke VNet CIDR (set at creation, **do not change**) |

**To update any of this, edit `domains.yaml` and open a PR. No `.tf` files need to change.**

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
6. CI runs `terraform plan` — you should see tag updates on Azure resources and
   `properties.owner` changes on the Unity Catalog catalog/schemas.
7. Merge. CI runs `terraform apply` automatically.

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

2. **A non-overlapping `/16` CIDR** for the spoke VNet.
   Current allocations:
   | Domain | CIDR |
   |---|---|
   | hub VNet | 10.0.0.0/16 |
   | ADB VNet | 10.1.0.0/16 |
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
      email:      "cs-data-team@contoso.com"
      escalation: "vp-cs@contoso.com"
      teams_channel: "Data Platform/Customer Success"
    network:
      address_space: "10.60.0.0/16"   # next available /16
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
module.domain_spoke["customer_success"].azurerm_resource_group.spoke    will be created
module.domain_spoke["customer_success"].azurerm_virtual_network.spoke   will be created
module.domain_spoke["customer_success"].azurerm_storage_account.domain  will be created
module.domain_spoke["customer_success"].azurerm_key_vault.domain        will be created
...
module.unity_catalog.databricks_catalog.domain["customer_success"]      will be created
module.unity_catalog.databricks_schema.raw["customer_success"]          will be created
module.unity_catalog.databricks_schema.curated["customer_success"]      will be created
module.unity_catalog.databricks_schema.published["customer_success"]    will be created
module.unity_catalog.databricks_schema.subject_area["customer_success__onboarding"]   will be created
...
```

**Step 5 — Merge**

CI runs `terraform apply`. The new domain is live within ~5 minutes.
No existing domains are affected.

---

## Adding a subject area to an existing domain

Subject areas are schemas in Unity Catalog. Adding one creates a new schema and
sets its ownership metadata. **No networking or storage changes occur.**

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

Only additions — no changes to existing schemas:
```
module.unity_catalog.databricks_schema.subject_area["finance__accounts_receivable"]  will be created
```

---

## Removing a subject area

Subject area removal is safe — it deletes the schema from Unity Catalog metadata only.
Underlying data in ADLS is **not deleted**.

1. Confirm the schema is empty (no tables) or data has been migrated.
2. Remove the entry from `domains.yaml`.
3. Open a PR — plan shows `databricks_schema ... will be destroyed`.
4. Merge only after data owner sign-off.

---

## Removing a domain

Domain removal is **irreversible for networking resources**. Follow this checklist:

- [ ] All data products using this domain have been decommissioned or migrated
- [ ] No active jobs, pipelines or notebooks reference the catalog
- [ ] Storage account data has been archived or deleted per retention policy
- [ ] Domain data owner and platform team have both signed off

Steps:
1. Remove the domain block from `domains.yaml`.
2. Open a PR labelled `breaking: decommission <domain>`.
3. Terraform plan shows destruction of spoke VNet, storage, Key Vault, catalog.
4. Require two approvals (domain owner + platform engineer).
5. After merge, storage account is soft-deleted for 30 days (blob versioning).
   Permanent deletion requires a separate `terraform apply -target` with the
   storage account purge policy lifted.

---

## Rotating group ownership (Entra group changes)

If the Entra group itself changes (e.g. group is recreated with a new Object ID):

1. Update the `access.*_group_id` field in `domains.yaml` with the new Object ID.
2. Open a PR — plan shows role assignment and Databricks grant updates.
3. Old group loses access on apply; new group gains access immediately.

---

## CI/CD integration

The recommended pipeline (`ci.yml` — adapt to your platform):

```yaml
on:
  pull_request:
    paths: ["domains.yaml", "**/*.tf"]
  push:
    branches: [main]
    paths: ["domains.yaml", "**/*.tf"]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: pip install pyyaml
      - run: python scripts/validate_domains.py

  plan:
    needs: validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init
      - run: terraform plan -out=tfplan
      - run: terraform show -no-color tfplan >> $GITHUB_STEP_SUMMARY

  apply:
    if: github.ref == 'refs/heads/main'
    needs: plan
    runs-on: ubuntu-latest
    environment: production          # requires manual approval gate
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init
      - run: terraform apply -auto-approve
```

---

## Quick reference

| Task | File to edit | Terraform impact |
|---|---|---|
| Update domain owner / Teams channel | `domains.yaml` | Tag updates only (fast, in-place) |
| Add subject area | `domains.yaml` | New schema created |
| Remove subject area | `domains.yaml` | Schema destroyed (data not deleted) |
| Add new domain | `domains.yaml` + create 3 Entra groups | New VNet, storage, KV, catalog created |
| Remove domain | `domains.yaml` | Destructive — requires sign-off |
| Change Entra group | `domains.yaml` | RBAC and grants updated |
| Change CIDR | ⚠️ **Not supported after first apply** | Would destroy/recreate VNet |
| Change infrastructure config | `terraform.tfvars` | Varies |
