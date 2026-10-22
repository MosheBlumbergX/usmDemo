#!/usr/bin/env bash
# Step 5: put the Confluent Cloud Enterprise cluster to work.
#   - CFK KafkaRestClasses + cloud topic `orders`
#   - source-initiated cluster link CP -> CCloud mirroring test1/test2
#   - Schema Linking CP SR -> CCloud SR (test2-value, same schema IDs)
#   - fully-managed Datagen connector -> orders
#   - consumer on EKS reading from CCloud over PrivateLink
source "$(dirname "$0")/lib.sh"
require kubectl envsubst jq curl

export CCLOUD_CLUSTER_ID CCLOUD_BOOTSTRAP CCLOUD_REST_ENDPOINT CP_CLUSTER_ID CCLOUD_SR_URL
CCLOUD_CLUSTER_ID="$(tf_out ccloud_cluster_id)"
CCLOUD_BOOTSTRAP="$(tf_out ccloud_cluster_bootstrap | sed -E 's#^[A-Z_]+://##')"
CCLOUD_REST_ENDPOINT="$(tf_out ccloud_cluster_rest_endpoint)"
CP_CLUSTER_ID="$(kubectl -n "$NS" get kafka kafka -o jsonpath='{.status.clusterID}')"
CCLOUD_SR_URL="$(tf_out ccloud_schema_registry_url)"
ENV_ID="$(tf_out ccloud_environment_id)"
SR_KEY="$(tf_out ccloud_sr_api_key)"
SR_SECRET="$(tf_out ccloud_sr_api_secret)"
KEY="$(tf_out ccloud_app_api_key)"
SECRET="$(tf_out ccloud_app_api_secret)"

log "creating Confluent Cloud secrets"
apply_secret ccloud-rest-credential \
  --from-literal=basic.txt="$(printf 'username=%s\npassword=%s' "$KEY" "$SECRET")"
apply_secret ccloud-link-jaas \
  --from-literal=plain-jaas.conf="sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"$KEY\" password=\"$SECRET\";"
apply_secret ccloud-client \
  --from-literal=BOOTSTRAP="$CCLOUD_BOOTSTRAP" \
  --from-literal=API_KEY="$KEY" \
  --from-literal=API_SECRET="$SECRET" \
  --from-literal=SR_URL="$CCLOUD_SR_URL" \
  --from-literal=SR_API_KEY="$SR_KEY" \
  --from-literal=SR_API_SECRET="$SR_SECRET"
apply_secret ccloud-sr-credential \
  --from-literal=basic.txt="$(printf 'username=%s\npassword=%s' "$SR_KEY" "$SR_SECRET")"
# Confluent Cloud certificates chain to Let's Encrypt (ISRG roots). Only ship
# those: the CA ends up inside the link config, which is capped at 32 KB.
ca_bundle="$(mktemp)"
kubectl -n "$NS" exec kafka-0 -c kafka -- \
  sed -n '/^# ISRG Root/,/END CERTIFICATE/p' /etc/pki/tls/certs/ca-bundle.crt >"$ca_bundle"
[[ -s "$ca_bundle" ]] || { echo "could not extract ISRG roots" >&2; exit 1; }
apply_secret ccloud-tls-certs --from-file=cacerts.pem="$ca_bundle"
rm -f "$ca_bundle"

log "REST classes + cloud topic"
apply_rendered "$REPO_ROOT/k8s/ccloud/00-rest-classes.yaml"

log "cluster link: destination side first, then source side"
apply_rendered "$REPO_ROOT/k8s/ccloud/10-link-destination.yaml"
wait_for clusterlink cp-to-cloud-dest 300 CREATED '{.status.state}'
apply_rendered "$REPO_ROOT/k8s/ccloud/20-link-source.yaml"
wait_for clusterlink cp-to-cloud-source 300 CREATED '{.status.state}'

log "schema linking: CP Schema Registry -> Confluent Cloud Schema Registry"
apply_rendered "$REPO_ROOT/k8s/ccloud/40-schema-exporter.yaml"
wait_for schemaexporter cp-to-cloud 300 RUNNING '{.status.exporterStatus}'

log "fully-managed Datagen connector -> orders"
ccloud_api PUT "/connect/v1/environments/$ENV_ID/clusters/$CCLOUD_CLUSTER_ID/connectors/datagen-orders/config" \
  -d "$(jq -n --arg sa "$(tf_out ccloud_app_service_account_id)" '{
    "connector.class": "DatagenSource",
    "name": "datagen-orders",
    "kafka.auth.mode": "SERVICE_ACCOUNT",
    "kafka.service.account.id": $sa,
    "kafka.topic": "orders",
    "output.data.format": "JSON",
    "quickstart": "ORDERS",
    "max.interval": "500",
    "tasks.max": "1"
  }')" | jq -c '{name, type: .type}'

# The consumer subscribes by regex; start it once the mirror topic exists so it
# doesn't wait for the next metadata refresh (5 min) to pick test1 up.
wait_for clusterlink cp-to-cloud-dest 300 ACTIVE '{.status.mirrorTopics.test1.status}'

log "consumer on EKS reading from Confluent Cloud"
kubectl apply -f "$REPO_ROOT/k8s/ccloud/30-cloud-consumer.yaml"
kubectl apply -f "$REPO_ROOT/k8s/ccloud/50-cloud-avro-consumer.yaml"

kubectl -n "$NS" get clusterlink
kubectl -n "$NS" get kafkatopic ccloud-orders
kubectl -n "$NS" get schemaexporter
