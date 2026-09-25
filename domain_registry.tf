# ---------------------------------------------------------------------------
# Domain Registry loader
#
# Reads domains.yaml and constructs local.domains, which is used everywhere
# instead of var.domains. var.domains can still be set to override specific
# domains (useful for automated CI pipelines or emergency patches).
# ---------------------------------------------------------------------------

locals {
  _yaml = yamldecode(file("${path.root}/domains.yaml"))

  # Normalise YAML structure → shape expected by all modules
  _domains_from_yaml = {
    for name, cfg in local._yaml.domains : name => {
      address_space      = cfg.network.address_space
      owner              = cfg.owner.email
      teams_channel      = try(cfg.owner.teams_channel, "")
      owners_group_id    = cfg.access.owners_group_id
      engineers_group_id = cfg.access.engineers_group_id
      viewers_group_id   = cfg.access.viewers_group_id
      catalog_comment    = try(cfg.description, "")
      subject_areas = [
        for sa in try(cfg.subject_areas, []) : {
          name    = sa.name
          comment = try(sa.description, "")
          owner   = try(sa.owner, cfg.owner.email)
        }
      ]
    }
  }

  # var.domains entries take precedence over YAML (for automation overrides).
  # In normal usage var.domains is null and only the YAML is used.
  domains = var.domains != null ? merge(local._domains_from_yaml, var.domains) : local._domains_from_yaml

  # Per-domain Azure tags – teams_channel surfaces in Azure Portal and cost reports
  domain_tags = {
    for domain_name, domain_cfg in local.domains : domain_name => merge(local.common_tags, {
      domain        = domain_name
      domain_owner  = domain_cfg.owner != "" ? domain_cfg.owner : var.owner
      teams_channel = domain_cfg.teams_channel
    })
  }
}
