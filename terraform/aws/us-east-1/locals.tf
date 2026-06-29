locals {
  lambda_image = "${aws_ecr_repository.overmind.repository_url}:${var.lambda_image_tag}"
}

locals {
  root_domain              = trimsuffix(var.domain_name, ".")
  computed_overmind_domain = var.overmind_subdomain == "" ? local.root_domain : "${var.overmind_subdomain}.${local.root_domain}"
  overmind_fqdn            = var.overmind_domain_name == "" ? local.computed_overmind_domain : trimsuffix(var.overmind_domain_name, ".")
  www_domain               = "www.${local.root_domain}"
  availability_zones       = length(var.availability_zones) == 0 ? data.aws_availability_zones.available[0].names : var.availability_zones
  route53_zone_id          = var.create_hosted_zone ? aws_route53_zone.domain[0].zone_id : (var.hosted_zone_id != "" ? var.hosted_zone_id : data.aws_route53_zone.selected[0].zone_id)
  certificate_sans = distinct(compact(concat(
    [local.www_domain, local.overmind_fqdn == local.root_domain ? "" : local.overmind_fqdn],
    var.certificate_sans
  )))
  email_from_address       = var.email_from_address == "" ? "no-reply@${local.root_domain}" : var.email_from_address
  lambda_enabled           = var.enable_lambda_overmind
  rds_proxy_enabled        = local.lambda_enabled && var.enable_rds_proxy
  lambda_db_host           = local.rds_proxy_enabled ? aws_db_proxy.overmind[0].endpoint : aws_db_instance.overmind.address
  api_custom_domains       = local.lambda_enabled ? toset(distinct([local.root_domain, local.www_domain, local.overmind_fqdn])) : toset([])
  lambda_subnet_ids        = var.lambda_create_nat_gateway ? aws_subnet.private[*].id : aws_subnet.public[*].id
  db_public_access_input   = trimspace(var.db_public_access_cidr)
  db_public_access_cidr    = local.db_public_access_input == "" ? "" : (strcontains(local.db_public_access_input, "/") ? local.db_public_access_input : "${local.db_public_access_input}/32")
  db_public_access_enabled = local.db_public_access_cidr != ""
  lambda_function_tiers = {
    low = {
      memory  = var.lambda_low_memory_mb
      timeout = var.lambda_low_timeout_seconds
    }
    medium = {
      memory  = var.lambda_medium_memory_mb
      timeout = var.lambda_medium_timeout_seconds
    }
    high = {
      memory  = var.lambda_high_memory_mb
      timeout = var.lambda_high_timeout_seconds
    }
  }
  lambda_route_tiers = {
    high = toset([
      "ANY /api/devices/{device_id}/rom-metadata",
      "ANY /api/drones/rom-metadata",
      "ANY /api/devices/{device_id}/master-roms",
      "ANY /api/master-roms",
      "ANY /api/devices/{device_id}/master-bios",
      "ANY /api/master-bios",
      "ANY /api/devices/{device_id}/master-artwork",
      "ANY /api/devices/{device_id}/sync-artwork-bulk",
      "ANY /api/devices/{device_id}/sync-system",
      "ANY /api/bulk-sync"
    ])
    medium = toset([
      "ANY /api/admin/{proxy+}",
      "ANY /api/devices",
      "ANY /api/devices/{device_id}",
      "ANY /api/devices/{device_id}/systems",
      "ANY /api/devices/{device_id}/roms",
      "ANY /api/devices/{device_id}/bios",
      "ANY /api/devices/{device_id}/sync-rom",
      "ANY /api/devices/{device_id}/sync-bios",
      "ANY /api/devices/{device_id}/sync-artwork",
      "ANY /api/devices/{device_id}/gameplay",
      "ANY /api/devices/{device_id}/game-logs",
      "ANY /api/devices/{device_id}/log-sources",
      "ANY /api/devices/{device_id}/emulator-configs",
      "ANY /api/devices/{device_id}/gamelogs",
      "ANY /api/downloads",
      "ANY /api/sync-activity",
      "ANY /api/hive",
      "ANY /api/swarms/{proxy+}",
      "ANY /api/swarms"
    ])
  }
  lambda_routes = merge(
    { for route in local.lambda_route_tiers.high : route => "high" },
    { for route in local.lambda_route_tiers.medium : route => "medium" }
  )
  scheduled_jobs = {
    # Must run at or below NOTIFICATION_AGGREGATION_WINDOW_MINUTES (default 3) so
    # every queued notification gets multiple delivery chances before it ages out
    # of the aggregation window.
    notification-delivery = "rate(3 minutes)"
    device-status         = "rate(5 minutes)"
    # The public-reachability probe defaults conditional on the Edge: OFF when the
    # Edge is enabled (OVERMIND_EDGE_ENABLED, which Terraform sets from enable_edge
    # on the Lambdas), ON without an Edge so cross-network drones keep a direct WAN
    # path. The rule always fires; the job no-ops cheaply when disabled. Kept on a
    # slow cadence; lower it if you run direct-WAN (port-forwarded) drones.
    public-reachability = "rate(15 minutes)"
  }
}
