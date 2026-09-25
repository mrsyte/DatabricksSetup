#!/usr/bin/env python3
"""
teams_notify.py  –  Post a deployment notification to a Microsoft Teams channel
                    via an Incoming Webhook (Teams Workflows connector).

Usage:
    python scripts/teams_notify.py \
        --webhook-url  "$TEAMS_DEPLOYMENTS_WEBHOOK_URL" \
        --environment  prod \
        --status       success \
        --actor        "jane.doe" \
        --run-url      "https://github.com/org/repo/actions/runs/12345" \
        --commit-sha   "abc1234def5678" \
        --commit-msg   "feat(domains): add customer_success domain"

Exit codes:
    0  – notification sent (or webhook URL not configured – treated as optional)
    1  – HTTP error or unexpected failure
"""

import argparse
import json
import subprocess
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False


# ---------------------------------------------------------------------------
# Domain change detection
# ---------------------------------------------------------------------------

def _load_yaml(text: str) -> dict:
    if not HAS_YAML:
        return {}
    try:
        return yaml.safe_load(text) or {}
    except Exception:
        return {}


def get_domain_changes() -> list[str]:
    """Compare HEAD with HEAD~1 on domains.yaml and return human-readable lines."""
    curr_path = Path("domains.yaml")
    if not curr_path.exists():
        return ["(domains.yaml not found)"]

    curr_data = _load_yaml(curr_path.read_text())
    curr_domains: dict = curr_data.get("domains", {})

    # Try to get the previous commit's version
    prev = subprocess.run(
        ["git", "show", "HEAD~1:domains.yaml"],
        capture_output=True, text=True
    )

    if prev.returncode != 0 or not prev.stdout.strip():
        # First commit or no previous version – treat everything as new
        lines = [f"• **{name}** — initial deployment" for name in sorted(curr_domains)]
        return lines or ["• No domains defined yet"]

    prev_data    = _load_yaml(prev.stdout)
    prev_domains = prev_data.get("domains", {})

    curr_keys = set(curr_domains)
    prev_keys = set(prev_domains)

    lines = []

    for name in sorted(curr_keys - prev_keys):
        ch = curr_domains[name].get("owner", {}).get("teams_channel", "")
        lines.append(f"• **{name}** — new domain added" + (f" ({ch})" if ch else ""))

    for name in sorted(prev_keys - curr_keys):
        lines.append(f"• **{name}** — domain removed")

    for name in sorted(curr_keys & prev_keys):
        curr_cfg = curr_domains[name]
        prev_cfg = prev_domains[name]
        mods = []

        curr_owner = curr_cfg.get("owner", {}).get("email", "")
        prev_owner = prev_cfg.get("owner", {}).get("email", "")
        if curr_owner != prev_owner:
            mods.append(f"owner changed → {curr_owner}")

        curr_ch = curr_cfg.get("owner", {}).get("teams_channel", "")
        prev_ch = prev_cfg.get("owner", {}).get("teams_channel", "")
        if curr_ch != prev_ch:
            mods.append(f"Teams channel → {curr_ch}")

        curr_sas = {sa["name"] for sa in curr_cfg.get("subject_areas", [])}
        prev_sas = {sa["name"] for sa in prev_cfg.get("subject_areas", [])}
        added_sas   = curr_sas - prev_sas
        removed_sas = prev_sas - curr_sas
        if added_sas:
            mods.append(f"subjects added: {', '.join(sorted(added_sas))}")
        if removed_sas:
            mods.append(f"subjects removed: {', '.join(sorted(removed_sas))}")

        if mods:
            lines.append(f"• **{name}** — {'; '.join(mods)}")

    return lines or ["• Infrastructure changes only (no domain changes)"]


# ---------------------------------------------------------------------------
# Adaptive Card builder
# ---------------------------------------------------------------------------

def build_card(
    env: str,
    status: str,
    actor: str,
    run_url: str,
    commit_sha: str,
    commit_msg: str,
    domain_changes: list[str],
) -> dict:
    is_success   = status.lower() in ("success", "succeeded")
    status_color = "Good" if is_success else "Attention"
    status_icon  = "✅" if is_success else "❌"
    status_label = "Succeeded" if is_success else "Failed"
    short_sha    = commit_sha[:7] if len(commit_sha) >= 7 else commit_sha
    timestamp    = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    env_upper    = env.upper()

    # Trim commit message to one line, max 120 chars
    first_line = (commit_msg.splitlines()[0] if commit_msg else "").strip()
    if len(first_line) > 120:
        first_line = first_line[:117] + "..."

    change_text = "\n".join(domain_changes) if domain_changes else "• No domain changes"

    card = {
        "type": "message",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "contentUrl": None,
                "content": {
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "msteams": {"width": "Full"},
                    "body": [
                        # ── Header ──────────────────────────────────────────
                        {
                            "type": "Container",
                            "style": status_color,
                            "bleed": True,
                            "items": [
                                {
                                    "type": "ColumnSet",
                                    "columns": [
                                        {
                                            "type": "Column",
                                            "width": "stretch",
                                            "items": [
                                                {
                                                    "type": "TextBlock",
                                                    "text": f"🚀 Databricks Platform Deployed — {env_upper}",
                                                    "weight": "Bolder",
                                                    "size": "Large",
                                                    "wrap": True,
                                                },
                                                {
                                                    "type": "TextBlock",
                                                    "text": f"{status_icon} **{status_label}** · @{actor} · {timestamp}",
                                                    "spacing": "None",
                                                    "wrap": True,
                                                },
                                            ],
                                        }
                                    ],
                                }
                            ],
                        },
                        # ── Domain Changes ──────────────────────────────────
                        {
                            "type": "Container",
                            "spacing": "Medium",
                            "items": [
                                {
                                    "type": "TextBlock",
                                    "text": "Domain Changes",
                                    "weight": "Bolder",
                                    "size": "Medium",
                                },
                                {
                                    "type": "TextBlock",
                                    "text": change_text,
                                    "wrap": True,
                                    "spacing": "Small",
                                },
                            ],
                        },
                        # ── Commit ──────────────────────────────────────────
                        {
                            "type": "FactSet",
                            "spacing": "Medium",
                            "facts": [
                                {"title": "Commit", "value": f"`{short_sha}` {first_line}"},
                                {"title": "Environment", "value": env_upper},
                                {"title": "Triggered by", "value": f"@{actor}"},
                            ],
                        },
                    ],
                    "actions": [
                        {
                            "type": "Action.OpenUrl",
                            "title": "View Workflow Run",
                            "url": run_url,
                        },
                        {
                            "type": "Action.OpenUrl",
                            "title": "View Commit",
                            "url": run_url.split("/actions/")[0] + f"/commit/{commit_sha}",
                        },
                    ],
                },
            }
        ],
    }
    return card


# ---------------------------------------------------------------------------
# HTTP POST
# ---------------------------------------------------------------------------

def post(webhook_url: str, payload: dict) -> None:
    data = json.dumps(payload).encode("utf-8")
    req  = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body   = resp.read().decode()
            status = resp.status
            if status not in (200, 202):
                print(f"ERROR: Teams responded HTTP {status}: {body}", file=sys.stderr)
                sys.exit(1)
            print(f"Teams notification sent (HTTP {status})")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        print(f"ERROR: HTTP {exc.code}: {body}", file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Post Teams deployment notification")
    parser.add_argument("--webhook-url",  required=True,  help="Teams Incoming Webhook URL")
    parser.add_argument("--environment",  required=True,  help="Deployment environment (dev/uat/prod)")
    parser.add_argument("--status",       required=True,  choices=["success", "failure"],
                        help="Job outcome")
    parser.add_argument("--actor",        required=True,  help="GitHub actor username")
    parser.add_argument("--run-url",      required=True,  help="URL of the GitHub Actions run")
    parser.add_argument("--commit-sha",   required=True,  help="Full commit SHA")
    parser.add_argument("--commit-msg",   default="",     help="First line of commit message")
    args = parser.parse_args()

    # Treat an empty/unset webhook URL as optional (don't fail the workflow)
    if not args.webhook_url or args.webhook_url.strip() in ("", "null", "None"):
        print("TEAMS_DEPLOYMENTS_WEBHOOK_URL not configured – skipping notification")
        return 0

    domain_changes = get_domain_changes()
    card = build_card(
        env=args.environment,
        status=args.status,
        actor=args.actor,
        run_url=args.run_url,
        commit_sha=args.commit_sha,
        commit_msg=args.commit_msg,
        domain_changes=domain_changes,
    )
    post(args.webhook_url, card)
    return 0


if __name__ == "__main__":
    sys.exit(main())
