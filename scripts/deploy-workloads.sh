#!/usr/bin/env bash
# Step 4: connectors + demo apps.
# Runs AFTER register-usm.sh: USM learns about a connector from the metadata event
# Connect emits when the connector is created. Connectors created before the
# Connect cluster is registered are rejected ("USM resource not found (Connector)").
source "$(dirname "$0")/lib.sh"
require kubectl envsubst

export S3_BUCKET AWS_REGION
S3_BUCKET="$(tf_out s3_sink_bucket)"
AWS_REGION="$(tf_out region)"

log "deploying connectors"
apply_rendered "$REPO_ROOT/k8s/connectors/connectors.yaml"

log "deploying demo apps"
kubectl apply -f "$REPO_ROOT/k8s/apps/"

sleep 20
kubectl -n "$NS" get connector
cat <<MSG

Done. Open Confluent Cloud -> Environments -> $(tf_out ccloud_environment_id) and look for
the "$(tf_out eks_cluster_name)" Confluent Platform cluster. Kafka Streams (ks-validate)
appears under the cluster's Kafka Streams page within ~1-2 minutes.
MSG
