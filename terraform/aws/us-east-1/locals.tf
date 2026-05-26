locals {
  image_version = "latest"
  image         = "${aws_ecr_repository.overmind.repository_url}:${local.image_version}"
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region              = var.aws_region
    ecr_repository_url      = aws_ecr_repository.overmind.repository_url
    ecr_registry_url        = split("/", aws_ecr_repository.overmind.repository_url)[0]
    image                   = local.image
    domain_name             = local.overmind_fqdn
    runtime_secret_id       = aws_secretsmanager_secret.overmind_runtime.arn
    internal_ca_secret_id   = var.enable_internal_ca_secret ? aws_secretsmanager_secret.internal_ca[0].arn : ""
    overmind_container_port = var.overmind_container_port
    environment             = var.environment
    overmind_version        = var.overmind_version
    use_fake_data           = var.use_fake_data
  })
}

locals {
  root_domain              = trimsuffix(var.domain_name, ".")
  computed_overmind_domain = var.overmind_subdomain == "" ? local.root_domain : "${var.overmind_subdomain}.${local.root_domain}"
  overmind_fqdn            = var.overmind_domain_name == "" ? local.computed_overmind_domain : trimsuffix(var.overmind_domain_name, ".")
  www_domain               = "www.${local.root_domain}"
  availability_zones       = length(var.availability_zones) == 0 ? data.aws_availability_zones.available[0].names : var.availability_zones
  instance_ami_id          = var.ami_id == "" ? data.aws_ami.amazon_linux_2023[0].id : var.ami_id
  route53_zone_id          = var.create_hosted_zone ? aws_route53_zone.domain[0].zone_id : (var.hosted_zone_id != "" ? var.hosted_zone_id : data.aws_route53_zone.selected[0].zone_id)
  certificate_sans = distinct(compact(concat(
    [local.www_domain, local.overmind_fqdn == local.root_domain ? "" : local.overmind_fqdn],
    var.certificate_sans
  )))
  email_from_address = var.email_from_address == "" ? "no-reply@${local.root_domain}" : var.email_from_address
}
