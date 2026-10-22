terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 2.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Reads CONFLUENT_CLOUD_API_KEY / CONFLUENT_CLOUD_API_SECRET from the environment
# (scripts/ source them from .env).
provider "confluent" {}

locals {
  tags = merge({
    Project   = var.name
    ManagedBy = "terraform"
  }, var.tags)
}
