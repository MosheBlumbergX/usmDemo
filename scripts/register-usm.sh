#!/usr/bin/env bash
# Step 3: register the CP Kafka cluster and Connect cluster with USM.
# Uses the USM REST API (same as `confluent usm kafka|connect register`) so it
# works with the Cloud API key in .env - no interactive `confluent login`.
source "$(dirname "$0")/lib.sh"
require kubectl jq curl

ENV_ID="$(tf_out ccloud_environment_id)"
REGION="$(tf_out region)"
NAME="$(tf_out eks_cluster_name)"

KAFKA_ID="$(kubectl -n "$NS" get kafka kafka -o jsonpath='{.status.clusterID}')"
CONNECT_ID="$(kubectl -n "$NS" get connect connect -o jsonpath='{.status.groupID}')"
[[ -n "$KAFKA_ID" && -n "$CONNECT_ID" ]] || { echo "CP not ready (kafka=$KAFKA_ID connect=$CONNECT_ID)"; exit 1; }

existing() { # $1 = kafka-clusters|connect-clusters, $2 = jq field, $3 = CP id
  ccloud_api GET "/usm/v1/$1?environment=$ENV_ID" | jq -r --arg f "$2" --arg id "$3" '.data[] | select(.[$f] == $id) | .id'
}

log "registering Kafka cluster $KAFKA_ID"
USM_KAFKA="$(existing kafka-clusters confluent_platform_kafka_cluster_id "$KAFKA_ID")"
if [[ -z "$USM_KAFKA" ]]; then
  ccloud_api POST /usm/v1/kafka-clusters -d "$(jq -n \
    --arg id "$KAFKA_ID" --arg name "$NAME" --arg region "$REGION" --arg env "$ENV_ID" \
    '{display_name: $name, confluent_platform_kafka_cluster_id: $id, cloud: "AWS", region: $region, environment: {id: $env}}')" | jq .
else
  echo "already registered as $USM_KAFKA"
fi

log "registering Connect cluster $CONNECT_ID"
USM_CONNECT="$(existing connect-clusters confluent_platform_connect_cluster_id "$CONNECT_ID")"
if [[ -z "$USM_CONNECT" ]]; then
  ccloud_api POST /usm/v1/connect-clusters -d "$(jq -n \
    --arg id "$CONNECT_ID" --arg kid "$KAFKA_ID" --arg region "$REGION" --arg env "$ENV_ID" \
    '{confluent_platform_connect_cluster_id: $id, kafka_cluster_id: $kid, cloud: "AWS", region: $region, environment: {id: $env}}')" | jq .
else
  echo "already registered as $USM_CONNECT"
fi

echo "Registered. Next: make workloads (connectors must be created after the Connect cluster is registered)."
