#!/usr/bin/env bash
# Step 1: AWS (VPC, EKS, S3, PrivateLink endpoint, Route53) + Confluent Cloud
# (environment, gateway, access point, USM service account + API keys).
source "$(dirname "$0")/lib.sh"
require terraform aws

log "terraform apply"
terraform -chdir="$TF_DIR" init -upgrade -input=false >/dev/null
terraform -chdir="$TF_DIR" apply -input=false -auto-approve

log "writing kubeconfig to $KUBECONFIG"
aws eks update-kubeconfig \
  --name "$(tf_out eks_cluster_name)" \
  --region "$(tf_out region)" \
  --kubeconfig "$KUBECONFIG" >/dev/null
kubectl get nodes
