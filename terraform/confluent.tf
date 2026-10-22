# Confluent Cloud side of USM:
#   - an environment with the ADVANCED Stream Governance package (required by USM)
#   - a service account for the USM Agent with UsmAgent + DataSteward roles
#   - a Cloud resource management API key for it (what the agent authenticates with)

resource "confluent_environment" "usm" {
  display_name = coalesce(var.ccloud_environment_name, var.name)

  stream_governance {
    package = "ADVANCED"
  }
}

resource "confluent_service_account" "usm_agent" {
  display_name = "${var.name}-usm-agent"
  description  = "USM Agent for the ${var.name} Confluent Platform cluster on EKS"
}

resource "confluent_role_binding" "usm_agent" {
  for_each = toset(["UsmAgent", "DataSteward"])

  principal   = "User:${confluent_service_account.usm_agent.id}"
  role_name   = each.key
  crn_pattern = confluent_environment.usm.resource_name
}

# Cloud resource management key (no managed_resource) - used by the USM Agent to
# talk to the CCloud front door.
resource "confluent_api_key" "usm_agent_cloud" {
  display_name = "${var.name}-usm-agent-cloud"
  description  = "USM Agent - Cloud resource management"

  owner {
    id          = confluent_service_account.usm_agent.id
    api_version = confluent_service_account.usm_agent.api_version
    kind        = confluent_service_account.usm_agent.kind
  }

  depends_on = [confluent_role_binding.usm_agent]
}
