# SASL/PLAIN users for the CP Kafka SASL listener. Generated per deployment so no
# credentials are ever committed; scripts/ turn these into Kubernetes secrets.

locals {
  sasl_users = ["kafka", "connect", "consumer"]
}

resource "random_password" "sasl" {
  for_each = toset(local.sasl_users)

  length  = 24
  special = false
}

# Encrypts the CCloud credentials stored in the CP-side (source) cluster link.
resource "random_password" "password_encoder" {
  length  = 32
  special = false
}
