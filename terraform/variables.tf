variable "name" {
  description = "Name prefix for every resource (EKS cluster, CCloud environment, ...)."
  type        = string
  default     = "usm-demo"
}

variable "region" {
  description = "AWS region. The CCloud PrivateLink gateway and USM metadata live in the same region."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Extra AWS tags applied to all resources."
  type        = map(string)
  default     = {}
}

# --- Networking / EKS --------------------------------------------------------

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "node_instance_type" {
  description = "Worker size. The full footprint (3 KRaft, 3 Kafka, 2 Connect, SR, USM Agent, apps, optional Flink) needs ~4x m5.xlarge."
  type        = string
  default     = "m5.xlarge"
}

variable "node_count" {
  type    = number
  default = 4
}

# --- Confluent Cloud ---------------------------------------------------------

variable "ccloud_environment_name" {
  description = "Name of the Confluent Cloud environment created for USM (Advanced Stream Governance)."
  type        = string
  default     = null
}
