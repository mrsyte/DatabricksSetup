#!/usr/bin/env python3
"""
validate_domains.py  –  Validate domains.yaml before Terraform runs.

Usage:
    python scripts/validate_domains.py [path/to/domains.yaml]

Exit codes:
    0  – valid
    1  – validation error(s) found
"""

import ipaddress
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml")
    sys.exit(1)

RESERVED_CIDRS = [
    ipaddress.ip_network("10.0.0.0/16"),   # hub VNet
    ipaddress.ip_network("10.1.0.0/16"),   # ADB VNet
    ipaddress.ip_network("172.16.0.0/22"), # VPN client pool
]

DOMAIN_NAME_RE  = re.compile(r'^[a-z][a-z0-9_]{1,30}$')
SUBJECT_NAME_RE = re.compile(r'^[a-z][a-z0-9_]{1,50}$')
EMAIL_RE        = re.compile(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
UUID_RE         = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    re.IGNORECASE,
)

errors = []


def err(msg: str) -> None:
    errors.append(msg)
    print(f"  ERROR: {msg}")


def warn(msg: str) -> None:
    print(f"  WARN:  {msg}")


def validate_email(value: str, field: str) -> None:
    if not EMAIL_RE.match(value):
        err(f"{field}: '{value}' is not a valid email address")


def validate_uuid(value: str, field: str) -> None:
    if not UUID_RE.match(value):
        err(f"{field}: '{value}' does not look like an Azure Object ID (UUID)")
    if "00000000" in value:
        warn(f"{field}: '{value}' still contains a placeholder UUID – replace with a real Object ID")


def validate_cidr(value: str, domain: str, seen: list) -> None:
    try:
        net = ipaddress.ip_network(value, strict=False)
    except ValueError:
        err(f"domain '{domain}' network.address_space: '{value}' is not a valid CIDR")
        return

    if net.prefixlen > 20:
        err(f"domain '{domain}': address_space /{net.prefixlen} is too small (use /20 or larger)")

    for reserved in RESERVED_CIDRS:
        if net.overlaps(reserved):
            err(f"domain '{domain}': address_space {value} overlaps reserved range {reserved}")

    for other_domain, other_net in seen:
        if net.overlaps(other_net):
            err(f"domain '{domain}': address_space {value} overlaps domain '{other_domain}' ({other_net})")

    seen.append((domain, net))


def main(path: str) -> int:
    p = Path(path)
    if not p.exists():
        print(f"ERROR: File not found: {path}")
        return 1

    with p.open() as fh:
        data = yaml.safe_load(fh)

    if not isinstance(data, dict) or "domains" not in data:
        print("ERROR: domains.yaml must have a top-level 'domains' key")
        return 1

    domains = data["domains"]
    if not isinstance(domains, dict) or len(domains) == 0:
        print("ERROR: 'domains' must be a non-empty map")
        return 1

    print(f"Validating {len(domains)} domain(s) in {path} ...\n")
    seen_cidrs: list = []

    for name, cfg in domains.items():
        print(f"[{name}]")

        # Domain name format
        if not DOMAIN_NAME_RE.match(name):
            err(f"domain name '{name}': must match ^[a-z][a-z0-9_]{{1,30}}$")

        # Required sections
        for section in ("owner", "network", "access"):
            if section not in cfg:
                err(f"domain '{name}': missing required section '{section}'")

        # Owner
        owner = cfg.get("owner", {})
        for field in ("email", "escalation"):
            val = owner.get(field, "")
            if not val:
                err(f"domain '{name}' owner.{field}: required but missing")
            else:
                validate_email(val, f"domain '{name}' owner.{field}")

        # Network
        network = cfg.get("network", {})
        cidr = network.get("address_space", "")
        if not cidr:
            err(f"domain '{name}' network.address_space: required but missing")
        else:
            validate_cidr(cidr, name, seen_cidrs)

        # Access
        access = cfg.get("access", {})
        for field in ("owners_group_id", "engineers_group_id", "viewers_group_id"):
            val = access.get(field, "")
            if not val:
                err(f"domain '{name}' access.{field}: required but missing")
            else:
                validate_uuid(val, f"domain '{name}' access.{field}")

        # Subject areas
        seen_subjects: set = set()
        for sa in cfg.get("subject_areas", []):
            sa_name = sa.get("name", "")
            if not sa_name:
                err(f"domain '{name}': subject area missing 'name'")
                continue
            if not SUBJECT_NAME_RE.match(sa_name):
                err(f"domain '{name}' subject '{sa_name}': name must match ^[a-z][a-z0-9_]{{1,50}}$")
            if sa_name in seen_subjects:
                err(f"domain '{name}': duplicate subject area '{sa_name}'")
            seen_subjects.add(sa_name)

            sa_owner = sa.get("owner", "")
            if sa_owner and not EMAIL_RE.match(sa_owner):
                err(f"domain '{name}' subject '{sa_name}' owner: '{sa_owner}' is not a valid email")

        print(f"  subjects: {list(seen_subjects) or '(none – only landing zones)'}")

    print()
    if errors:
        print(f"Validation FAILED with {len(errors)} error(s).")
        return 1

    print(f"Validation PASSED. {len(domains)} domain(s) OK.")
    return 0


if __name__ == "__main__":
    yaml_path = sys.argv[1] if len(sys.argv) > 1 else "domains.yaml"
    sys.exit(main(yaml_path))
