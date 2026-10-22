#!/usr/bin/env bash
# Step 2: CFK operator + Confluent Platform + USM Agent.
# Connectors/apps come after USM registration (scripts/deploy-workloads.sh).
source "$(dirname "$0")/lib.sh"
require kubectl helm envsubst jq

export CCLOUD_ENV_ID USM_FRONTDOOR_URL S3_BUCKET AWS_REGION
CCLOUD_ENV_ID="$(tf_out ccloud_environment_id)"
USM_FRONTDOOR_URL="$(tf_out usm_frontdoor_url)"
S3_BUCKET="$(tf_out s3_sink_bucket)"
AWS_REGION="$(tf_out region)"

# --- CFK operator (cluster-scoped) -------------------------------------------
log "installing CFK (chart $CFK_CHART_VERSION)"
helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo update confluentinc >/dev/null

# helm upgrade never updates CRDs, so apply them explicitly first.
tmp="$(mktemp -d)"
helm pull confluentinc/confluent-for-kubernetes --version "$CFK_CHART_VERSION" --untar --untardir "$tmp"
kubectl apply --server-side --force-conflicts -f "$tmp/confluent-for-kubernetes/crds/" >/dev/null
rm -rf "$tmp"

helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --version "$CFK_CHART_VERSION" \
  --namespace confluent --create-namespace \
  --set namespaced=false \
  --wait
kubectl -n confluent rollout status deploy/confluent-operator

# --- Base + secrets ----------------------------------------------------------
kubectl apply -f "$REPO_ROOT/k8s/cfk/00-base.yaml"

log "creating secrets from Terraform outputs"
pw="$(tf_out_json sasl_passwords)"
pass() { jq -r --arg u "$1" '.[$u]' <<<"$pw"; }

apply_secret sasl-credential \
  --from-literal=plain-users.json="$(jq -c . <<<"$pw")" \
  --from-literal=plain-interbroker.txt="$(printf 'username=kafka\npassword=%s' "$(pass kafka)")"

apply_secret connect-kafka-credential \
  --from-literal=plain.txt="$(printf 'username=connect\npassword=%s' "$(pass connect)")"

apply_secret kafka-client-consumer \
  --from-literal=SASL_USERNAME=consumer \
  --from-literal=SASL_PASSWORD="$(pass consumer)"

apply_secret password-encoder \
  --from-literal=password-encoder.txt="password=$(tf_out password_encoder_secret)"

apply_secret ccloud-usm-agent-credential \
  --from-literal=basic.txt="$(printf 'username=%s\npassword=%s' "$(tf_out usm_agent_api_key)" "$(tf_out usm_agent_api_secret)")"

# --- Confluent Platform ------------------------------------------------------
log "deploying Confluent Platform"
for f in "$REPO_ROOT"/k8s/cfk/[1-9]*.yaml; do
  apply_rendered "$f"
done

wait_for kraftcontroller kraftcontroller
wait_for kafka kafka
wait_for usmagent usm-agent
wait_for schemaregistry schemaregistry
wait_for connect connect 1200

kubectl -n "$NS" get kraftcontroller,kafka,connect,schemaregistry,usmagent,kafkatopic
