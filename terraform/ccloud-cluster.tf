# A Confluent Cloud Enterprise cluster next to the USM-managed CP cluster.
#   - Enterprise clusters are serverless and private-only; they reuse the same
#     ingress PrivateLink gateway/access point the USM Agent uses, so CP on EKS
#     reaches it over PrivateLink with no extra networking.
#   - CP mirrors topics into it through a source-initiated cluster link
#     (k8s/ccloud/), and a fully-managed Datagen connector produces `orders`.

resource "confluent_kafka_cluster" "cloud" {
  display_name = "${var.name}-cloud"
  availability = "LOW"
  cloud        = "AWS"
  region       = var.region

  enterprise {}

  environment {
    id = confluent_environment.usm.id
  }

  depends_on = [confluent_access_point.usm]
}

locals {
  # Endpoints served through our access point (the cluster's own
  # bootstrap_endpoint/rest_endpoint may point at a different access point).
  ccloud_cluster_endpoint = one([
    for e in confluent_kafka_cluster.cloud.endpoints : e
    if e.access_point_id == confluent_access_point.usm.id
  ])
}

# Used by CFK (KafkaRestClass + cluster link), the managed connector and the
# cloud consumer app. CloudClusterAdmin keeps the demo simple; scope it down
# for anything real.
resource "confluent_service_account" "cloud_app" {
  display_name = "${var.name}-cloud-app"
  description  = "CFK cluster link, managed connector and demo apps on ${var.name}-cloud"
}

resource "confluent_role_binding" "cloud_app" {
  principal   = "User:${confluent_service_account.cloud_app.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.cloud.rbac_crn
}

resource "confluent_api_key" "cloud_app" {
  display_name = "${var.name}-cloud-app"
  description  = "Kafka API key for ${var.name}-cloud"

  # The provider would verify the key against the cluster's REST endpoint, which
  # is PrivateLink-only and unreachable from where Terraform runs.
  disable_wait_for_ready = true

  owner {
    id          = confluent_service_account.cloud_app.id
    api_version = confluent_service_account.cloud_app.api_version
    kind        = confluent_service_account.cloud_app.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.cloud.id
    api_version = confluent_kafka_cluster.cloud.api_version
    kind        = confluent_kafka_cluster.cloud.kind

    environment {
      id = confluent_environment.usm.id
    }
  }

  depends_on = [confluent_role_binding.cloud_app]
}

# --- Schema Linking target ---------------------------------------------------
# The environment's Schema Registry is provisioned with the first Kafka cluster.
# The CP Schema Registry exports schemas into it (k8s/ccloud/40-schema-exporter.yaml).

data "confluent_schema_registry_cluster" "cloud" {
  environment {
    id = confluent_environment.usm.id
  }

  depends_on = [confluent_kafka_cluster.cloud]
}

# DataSteward lets the exporter register schemas and set subjects to IMPORT mode.
resource "confluent_role_binding" "cloud_app_sr" {
  principal   = "User:${confluent_service_account.cloud_app.id}"
  role_name   = "DataSteward"
  crn_pattern = confluent_environment.usm.resource_name
}

resource "confluent_api_key" "cloud_app_sr" {
  display_name = "${var.name}-cloud-app-sr"
  description  = "Schema Registry API key (schema exporter, Avro consumer)"

  # The SR endpoint used here is PrivateLink-only, see confluent_api_key.cloud_app.
  disable_wait_for_ready = true

  owner {
    id          = confluent_service_account.cloud_app.id
    api_version = confluent_service_account.cloud_app.api_version
    kind        = confluent_service_account.cloud_app.kind
  }

  managed_resource {
    id          = data.confluent_schema_registry_cluster.cloud.id
    api_version = data.confluent_schema_registry_cluster.cloud.api_version
    kind        = data.confluent_schema_registry_cluster.cloud.kind

    environment {
      id = confluent_environment.usm.id
    }
  }

  depends_on = [confluent_role_binding.cloud_app_sr]
}
