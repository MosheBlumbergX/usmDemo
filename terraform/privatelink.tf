# USM Agent -> Confluent Cloud traffic must go over PrivateLink.
#   1. CCloud ingress PrivateLink gateway  (gives us a VPC endpoint service name)
#   2. AWS interface VPC endpoint to it    (private DNS disabled)
#   3. CCloud access point                 (registers the VPC endpoint)
#   4. Route53 private zone *.<dns_domain> -> VPC endpoint

resource "confluent_gateway" "usm" {
  display_name = "${var.name}-ingress"

  environment {
    id = confluent_environment.usm.id
  }

  aws_ingress_private_link_gateway {
    region = var.region
  }
}

resource "aws_security_group" "ccloud_privatelink" {
  name        = "${var.name}-ccloud-privatelink"
  description = "Confluent Cloud PrivateLink endpoint (USM)"
  vpc_id      = module.vpc.vpc_id

  dynamic "ingress" {
    for_each = [80, 443, 9092]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_endpoint" "ccloud" {
  vpc_id              = module.vpc.vpc_id
  service_name        = confluent_gateway.usm.aws_ingress_private_link_gateway[0].vpc_endpoint_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.ccloud_privatelink.id]
  private_dns_enabled = false

  tags = { Name = "${var.name}-ccloud" }
}

resource "confluent_access_point" "usm" {
  display_name = "${var.name}-eks"

  environment {
    id = confluent_environment.usm.id
  }

  gateway {
    id = confluent_gateway.usm.id
  }

  aws_ingress_private_link_endpoint {
    vpc_endpoint_id = aws_vpc_endpoint.ccloud.id
  }
}

locals {
  # e.g. ap123abc.us-east-1.aws.accesspoint.confluent.cloud
  ccloud_dns_domain = confluent_access_point.usm.aws_ingress_private_link_endpoint[0].dns_domain
  # The global (glb) name resolves publicly to a CNAME under ccloud_dns_domain,
  # which our private zone points at the VPC endpoint.
  ccloud_glb_domain = replace(local.ccloud_dns_domain, ".accesspoint.confluent.cloud", ".accesspoint.glb.confluent.cloud")
  usm_frontdoor_url = "https://api-${local.ccloud_glb_domain}:443"
}

resource "aws_route53_zone" "ccloud" {
  name = local.ccloud_dns_domain

  vpc {
    vpc_id = module.vpc.vpc_id
  }
}

resource "aws_route53_record" "ccloud_wildcard" {
  zone_id = aws_route53_zone.ccloud.zone_id
  name    = "*.${local.ccloud_dns_domain}"
  type    = "CNAME"
  ttl     = 60
  records = [aws_vpc_endpoint.ccloud.dns_entry[0].dns_name]
}
