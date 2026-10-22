#!/usr/bin/env bash
# OPTIONAL: CP Flink - Flink Kubernetes operator + CMF (Helm), CFK FlinkEnvironment,
# then a compute pool, Kafka catalog and the drop-gender SQL statement via the
# CMF REST API. (CMF compiles statements into FlinkDeployments, so the job itself
# can't be a static manifest.)
source "$(dirname "$0")/lib.sh"
require kubectl helm jq curl

FLINK_OPERATOR_CHART="${FLINK_OPERATOR_CHART:-1.140.1}" # operator 1.14.0-cp1
CMF_CHART="${CMF_CHART:-2.3.1}"
CMF_PORT=18080

helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo update confluentinc >/dev/null

log "installing Flink operator $FLINK_OPERATOR_CHART + CMF $CMF_CHART"
kubectl create namespace flink --dry-run=client -o yaml | kubectl apply -f -
# Webhook disabled so cert-manager isn't required for the demo.
helm upgrade --install cp-flink-kubernetes-operator confluentinc/flink-kubernetes-operator \
  --version "$FLINK_OPERATOR_CHART" -n flink \
  --set watchNamespaces='{flink}' --set webhook.create=false --wait
helm upgrade --install cmf confluentinc/confluent-manager-for-apache-flink \
  --version "$CMF_CHART" -n flink \
  --set persistence.storageClassName=gp3 --wait

kubectl apply -f "$REPO_ROOT/k8s/flink/cfk-flink.yaml"

log "port-forwarding CMF to localhost:$CMF_PORT"
kubectl -n flink port-forward svc/cmf-service "$CMF_PORT:80" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
CMF="http://localhost:$CMF_PORT/cmf/api/v1"
until curl -sf "$CMF/environments" >/dev/null; do sleep 2; done

until curl -sf "$CMF/environments/env1" >/dev/null; do
  echo "waiting for FlinkEnvironment env1 to sync to CMF..."; sleep 5
done

cmf_put() { # $1 = collection path, $2 = name, $3 = json file/body
  if curl -sf "$CMF/$1/$2" >/dev/null; then
    echo "  $1/$2 exists"
  else
    curl -sS -f -X POST -H 'Content-Type: application/json' "$CMF/$1" -d "$3" | jq -c '{kind, name: .metadata.name}'
  fi
}

log "creating compute pool, catalog, statement"
cmf_put environments/env1/compute-pools pool1 "@$REPO_ROOT/k8s/flink/cmf/compute-pool.json"
cmf_put catalogs/kafka kafka-cat "@$REPO_ROOT/k8s/flink/cmf/catalog.json"
# CMF 2.3+: Kafka-backed databases are their own resource, not part of the catalog spec.
cmf_put catalogs/kafka/kafka-cat/databases kafka-db "@$REPO_ROOT/k8s/flink/cmf/database.json"

STATEMENT="$(jq -n --rawfile sql "$REPO_ROOT/k8s/flink/cmf/drop-gender.sql" '{
  apiVersion: "cmf.confluent.io/v1",
  kind: "Statement",
  metadata: { name: "drop-gender" },
  spec: {
    statement: ($sql | split("\n") | map(select(startswith("--") | not)) | join("\n")),
    properties: { "sql.current-catalog": "kafka-cat", "sql.current-database": "kafka-db" },
    computePoolName: "pool1",
    parallelism: 1,
    stopped: false
  }
}')"
cmf_put environments/env1/statements drop-gender "$STATEMENT"

kubectl -n flink get flinkdeployment,pods
