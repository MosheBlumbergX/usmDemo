#!/usr/bin/env bash
# Step 6: self-managed Connect on EKS backed by the Confluent Cloud cluster.
#   - Connect CR `connect-cloud` bootstrapping the Enterprise cluster over PrivateLink
#   - USM registration of that Connect cluster against the lkc- (not the CP cluster)
#   - Datagen connector -> stock-trades (cloud topic), created after registration
# Needs make ccloud first (krc-cloud REST class, ccloud-* secrets).
source "$(dirname "$0")/lib.sh"
require kubectl envsubst jq curl

export CCLOUD_BOOTSTRAP
CCLOUD_BOOTSTRAP="$(tf_out ccloud_cluster_bootstrap | sed -E 's#^[A-Z_]+://##')"
CCLOUD_CLUSTER_ID="$(tf_out ccloud_cluster_id)"
ENV_ID="$(tf_out ccloud_environment_id)"
REGION="$(tf_out region)"

log "Confluent Cloud credential for connect-cloud"
apply_secret ccloud-connect-credential \
  --from-literal=plain.txt="$(printf 'username=%s\npassword=%s' "$(tf_out ccloud_app_api_key)" "$(tf_out ccloud_app_api_secret)")"

log "Connect cluster connect-cloud (Kafka = $CCLOUD_CLUSTER_ID)"
apply_rendered "$REPO_ROOT/k8s/ccloud/70-connect-cloud.yaml"
wait_for connect connect-cloud 900

CONNECT_ID="$(kubectl -n "$NS" get connect connect-cloud -o jsonpath='{.status.groupID}')"
[[ -n "$CONNECT_ID" ]] || { echo "connect-cloud has no groupID yet" >&2; exit 1; }

log "registering Connect cluster $CONNECT_ID with USM (kafka_cluster_id=$CCLOUD_CLUSTER_ID)"
USM_CONNECT="$(ccloud_api GET "/usm/v1/connect-clusters?environment=$ENV_ID" |
  jq -r --arg id "$CONNECT_ID" '.data[] | select(.confluent_platform_connect_cluster_id == $id) | .id')"
if [[ -z "$USM_CONNECT" ]]; then
  ccloud_api POST /usm/v1/connect-clusters -d "$(jq -n \
    --arg id "$CONNECT_ID" --arg kid "$CCLOUD_CLUSTER_ID" --arg region "$REGION" --arg env "$ENV_ID" \
    '{confluent_platform_connect_cluster_id: $id, kafka_cluster_id: $kid, cloud: "AWS", region: $region, environment: {id: $env}}')" | jq .
else
  echo "already registered as $USM_CONNECT"
fi

log "connector datagen-stock-trades -> stock-trades"
kubectl apply -f "$REPO_ROOT/k8s/ccloud/71-connector-cloud.yaml"
sleep 20
kubectl -n "$NS" get connect connect-cloud
kubectl -n "$NS" get connector datagen-stock-trades
