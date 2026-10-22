output "region" {
  value = var.region
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "s3_sink_bucket" {
  value = aws_s3_bucket.sink.bucket
}

output "ccloud_environment_id" {
  value = confluent_environment.usm.id
}

output "ccloud_access_point_dns_domain" {
  value = local.ccloud_dns_domain
}

# Equivalent of the FRONTDOOR_URL in the USM registration wizard's config file.
output "usm_frontdoor_url" {
  value = local.usm_frontdoor_url
}

output "usm_agent_api_key" {
  value     = confluent_api_key.usm_agent_cloud.id
  sensitive = true
}

output "usm_agent_api_secret" {
  value     = confluent_api_key.usm_agent_cloud.secret
  sensitive = true
}

output "sasl_passwords" {
  value     = { for u, p in random_password.sasl : u => p.result }
  sensitive = true
}

# --- Confluent Cloud Enterprise cluster ---------------------------------------

output "ccloud_cluster_id" {
  value = confluent_kafka_cluster.cloud.id
}

output "ccloud_cluster_bootstrap" {
  description = "Private (PrivateLink) bootstrap endpoint, reachable from the EKS VPC."
  value       = local.ccloud_cluster_endpoint.bootstrap_endpoint
}

output "ccloud_cluster_rest_endpoint" {
  value = local.ccloud_cluster_endpoint.rest_endpoint
}

output "ccloud_app_service_account_id" {
  value = confluent_service_account.cloud_app.id
}

output "ccloud_app_api_key" {
  value     = confluent_api_key.cloud_app.id
  sensitive = true
}

output "ccloud_app_api_secret" {
  value     = confluent_api_key.cloud_app.secret
  sensitive = true
}

output "password_encoder_secret" {
  value     = random_password.password_encoder.result
  sensitive = true
}

# --- Confluent Cloud Schema Registry (Schema Linking target) -----------------

output "ccloud_schema_registry_id" {
  value = data.confluent_schema_registry_cluster.cloud.id
}

output "ccloud_schema_registry_private_endpoints" {
  value = data.confluent_schema_registry_cluster.cloud.private_regional_rest_endpoints
}

# Same naming scheme as the Kafka endpoints: <lsrc-id>-<ap-id>.<region>...glb
output "ccloud_schema_registry_url" {
  value = "https://${data.confluent_schema_registry_cluster.cloud.id}-${local.ccloud_glb_domain}"
}

output "ccloud_sr_api_key" {
  value     = confluent_api_key.cloud_app_sr.id
  sensitive = true
}

output "ccloud_sr_api_secret" {
  value     = confluent_api_key.cloud_app_sr.secret
  sensitive = true
}
