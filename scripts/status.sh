#!/usr/bin/env bash
# Quick health check of the CP side and the USM registration.
source "$(dirname "$0")/lib.sh"

kubectl -n "$NS" get kraftcontroller,kafka,connect,schemaregistry,usmagent,connector
echo
kubectl -n "$NS" get pods -o wide
echo
log "ks-validate consumer group"
kubectl -n "$NS" exec kafka-0 -c kafka -- \
  kafka-consumer-groups --bootstrap-server localhost:9071 --describe --group ks-validate --state 2>/dev/null || true
echo
ENV_ID="$(tf_out ccloud_environment_id)"
log "USM registrations in $ENV_ID"
ccloud_api GET "/usm/v1/kafka-clusters?environment=$ENV_ID" | jq -r '.data[] | "kafka   \(.id)  \(.display_name)  cp=\(.confluent_platform_kafka_cluster_id)"'
ccloud_api GET "/usm/v1/connect-clusters?environment=$ENV_ID" | jq -r '.data[] | "connect \(.id)  cp=\(.confluent_platform_connect_cluster_id)"'
