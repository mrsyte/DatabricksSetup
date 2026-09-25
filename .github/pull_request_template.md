## Summary

<!-- What does this PR change and why? -->

## Type of change

- [ ] New domain (add to `domains.yaml`)
- [ ] New subject area (add to `domains.yaml`)
- [ ] Owner / contact update (`domains.yaml`)
- [ ] Terraform infrastructure change (`.tf` files)
- [ ] Environment config (`environments/*/terraform.tfvars`)
- [ ] CI/CD pipeline change

## Checklist

- [ ] `python scripts/validate_domains.py` passes locally
- [ ] `terraform fmt -recursive` run (no format changes)
- [ ] Terraform plan reviewed in the PR comments below (all 3 environments)
- [ ] No secrets committed (no real UUIDs, emails, or credentials in YAML/tfvars)
- [ ] For new domains: Entra group Object IDs confirmed by Azure AD admin
- [ ] For new domains: CIDR confirmed non-overlapping (validation script checks this)
- [ ] For destructive changes: domain/data owner sign-off obtained

## Plan summary

<!-- CI posts plan output automatically – paste key changes here for reviewers -->

## Notes for reviewer
