#!/usr/bin/env python3
"""
workspace_bootstrap.py  –  Apply workspace-level configuration to every
                            domain Databricks workspace after terraform apply.

Configures per workspace (idempotent):
  • Workspace security settings (workspace-conf)
  • Default cluster policy enforcing mandatory tags
  • Key Vault–backed secret scope per domain

Prerequisites:
  • Network access to each workspace's private endpoint (run on VPN or
    from a self-hosted runner inside the hub VNet)
  • Service principal with Databricks workspace admin role

Usage:
    # workspaces.json is produced by: terraform output -json domain_workspace_urls
    python scripts/workspace_bootstrap.py workspaces.json

    # or pipe directly:
    terraform output -json domain_workspace_urls | python scripts/workspace_bootstrap.py -

Environment variables (required):
    DATABRICKS_CLIENT_ID      – SP application (client) ID
    DATABRICKS_CLIENT_SECRET  – SP client secret
    AZURE_TENANT_ID           – Azure AD tenant ID

Environment variables (optional):
    KEYVAULT_IDS_JSON         – JSON from: terraform output -json domain_keyvault_uris
                                If set, creates KV-backed secret scopes.

Exit codes:
    0  – all workspaces configured (or skipped)
    1  – one or more workspaces failed
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

def _get_token(workspace_url: str, tenant_id: str, client_id: str, client_secret: str) -> str:
    """Exchange SP credentials for a Databricks personal access token (AAD token)."""
    resource = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"  # Databricks resource ID
    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/token"
    body = urllib.parse.urlencode({
        "grant_type":    "client_credentials",
        "client_id":     client_id,
        "client_secret": client_secret,
        "resource":      resource,
    }).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())["access_token"]


def _api(workspace_url: str, token: str, method: str, path: str,
         body: dict | None = None) -> Any:
    """Make a Databricks REST API call."""
    url  = f"{workspace_url.rstrip('/')}{path}"
    data = json.dumps(body).encode() if body else None
    req  = urllib.request.Request(
        url, data=data, method=method,
        headers={
            "Authorization":  f"Bearer {token}",
            "Content-Type":   "application/json",
            "Accept":         "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode()
        raise RuntimeError(f"HTTP {exc.code} {method} {path}: {body_text}") from exc


# ---------------------------------------------------------------------------
# Per-workspace configuration
# ---------------------------------------------------------------------------

WORKSPACE_CONF = {
    "enableResultsDownloading":     "false",
    "enableExportNotebook":         "false",
    "enableClusterAccessControl":   "true",
    "enableWorkspaceFilesystem":    "false",
    "enableTokensConfig":           "true",
    "maxTokenLifetimeDays":         "90",
    "enableJobsAccessControl":      "true",
    "enableNotebookTableClipboard": "false",
}

CLUSTER_POLICY_NAME = "Platform Default – Required Tags"

CLUSTER_POLICY_DEFINITION = {
    "custom_tags.app": {
        "type":  "fixed",
        "value": "databricks-platform",
    },
    "custom_tags.managed_by": {
        "type":  "fixed",
        "value": "databricks",
    },
    # owner and domain are required but user-supplied per cluster
    "custom_tags.owner": {
        "type":         "regex",
        "pattern":      ".+",
        "defaultValue": "",
    },
    "custom_tags.domain": {
        "type":         "regex",
        "pattern":      ".+",
        "defaultValue": "",
    },
    "custom_tags.cost_center": {
        "type":         "regex",
        "pattern":      ".+",
        "defaultValue": "data-platform",
    },
}


def configure_workspace_conf(workspace_url: str, token: str, domain: str) -> None:
    conf = dict(WORKSPACE_CONF)
    _api(workspace_url, token, "PATCH", "/api/2.0/workspace-conf", conf)
    print(f"  [workspace-conf] updated")


def configure_cluster_policy(workspace_url: str, token: str, domain: str) -> None:
    defn_json = json.dumps(CLUSTER_POLICY_DEFINITION)

    # List existing policies
    existing = _api(workspace_url, token, "GET", "/api/2.0/policies/clusters/list")
    policies = existing.get("policies", [])
    match    = next((p for p in policies if p["name"] == CLUSTER_POLICY_NAME), None)

    if match:
        _api(workspace_url, token, "PUT", "/api/2.0/policies/clusters/edit", {
            "policy_id":  match["policy_id"],
            "name":       CLUSTER_POLICY_NAME,
            "definition": defn_json,
        })
        print(f"  [cluster-policy] updated (id={match['policy_id']})")
    else:
        resp = _api(workspace_url, token, "POST", "/api/2.0/policies/clusters/create", {
            "name":       CLUSTER_POLICY_NAME,
            "definition": defn_json,
        })
        print(f"  [cluster-policy] created (id={resp.get('policy_id')})")


def configure_secret_scope(workspace_url: str, token: str, domain: str,
                            kv_resource_id: str, kv_dns_name: str) -> None:
    scope_name = domain

    # Check if scope already exists
    scopes = _api(workspace_url, token, "GET", "/api/2.0/secrets/scopes/list")
    existing_names = {s["name"] for s in scopes.get("scopes", [])}

    if scope_name in existing_names:
        print(f"  [secret-scope] '{scope_name}' already exists – skipping")
        return

    _api(workspace_url, token, "POST", "/api/2.0/secrets/scopes/create", {
        "scope":             scope_name,
        "scope_backend_type": "AZURE_KEYVAULT",
        "backend_azure_keyvault": {
            "resource_id": kv_resource_id,
            "dns_name":    kv_dns_name,
        },
        "initial_manage_principal": "users",
    })
    print(f"  [secret-scope] '{scope_name}' created (KV-backed)")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def bootstrap_domain(domain: str, workspace_url: str, token: str,
                     kv_ids: dict[str, str]) -> bool:
    print(f"\n[{domain}] {workspace_url}")
    try:
        configure_workspace_conf(workspace_url, token, domain)
        configure_cluster_policy(workspace_url, token, domain)

        if domain in kv_ids:
            kv_id  = kv_ids[domain]
            # Derive DNS name from resource ID: .../vaults/<name>
            kv_name    = kv_id.rstrip("/").split("/")[-1]
            kv_dns     = f"https://{kv_name}.vault.azure.net/"
            configure_secret_scope(workspace_url, token, domain, kv_id, kv_dns)
        else:
            print(f"  [secret-scope] no Key Vault ID available – skipping")

        print(f"  OK")
        return True
    except Exception as exc:
        print(f"  ERROR: {exc}", file=sys.stderr)
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Bootstrap domain Databricks workspaces")
    parser.add_argument("workspaces_json", help="Path to workspace URLs JSON, or '-' for stdin")
    args = parser.parse_args()

    tenant_id     = os.environ.get("AZURE_TENANT_ID", "")
    client_id     = os.environ.get("DATABRICKS_CLIENT_ID", "")
    client_secret = os.environ.get("DATABRICKS_CLIENT_SECRET", "")
    kv_ids_raw    = os.environ.get("KEYVAULT_IDS_JSON", "{}")

    for name, val in [("AZURE_TENANT_ID", tenant_id),
                       ("DATABRICKS_CLIENT_ID", client_id),
                       ("DATABRICKS_CLIENT_SECRET", client_secret)]:
        if not val:
            print(f"ERROR: {name} environment variable is required", file=sys.stderr)
            return 1

    if args.workspaces_json == "-":
        workspaces: dict[str, str] = json.load(sys.stdin)
    else:
        with open(args.workspaces_json) as fh:
            workspaces = json.load(fh)

    kv_ids: dict[str, str] = json.loads(kv_ids_raw)

    if not workspaces:
        print("No workspaces found – nothing to do")
        return 0

    print(f"Bootstrapping {len(workspaces)} workspace(s) ...")
    failures = 0

    for domain, workspace_url in sorted(workspaces.items()):
        try:
            token = _get_token(workspace_url, tenant_id, client_id, client_secret)
        except Exception as exc:
            print(f"\n[{domain}] ERROR getting token: {exc}", file=sys.stderr)
            failures += 1
            continue

        if not bootstrap_domain(domain, workspace_url, token, kv_ids):
            failures += 1

    print(f"\n{'All workspaces bootstrapped successfully.' if not failures else f'{failures} workspace(s) failed.'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
