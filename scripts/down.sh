#!/usr/bin/env bash
# Tear everything down: USM registrations -> CP (so EBS volumes are released)
# -> Terraform (EKS, VPC, PrivateLink, CCloud environment).
source "$(dirname "$0")/lib.sh"

# Laptop side of make console: port-forward, /etc/hosts, pf (sudo if set up).
"$REPO_ROOT/scripts/console.sh" stop || warn "console cleanup failed; run make console-stop"
"$REPO_ROOT/scripts/c3.sh" stop || true

if ENV_ID="$(tf_out ccloud_environment_id 2>/dev/null)" && [[ -n "$ENV_ID" ]]; then
  if LKC="$(tf_out ccloud_cluster_id 2>/dev/null)"; then
    log "deleting managed connector datagen-orders"
    ccloud_api DELETE "/connect/v1/environments/$ENV_ID/clusters/$LKC/connectors/datagen-orders" >/dev/null || true
  fi
  log "deregistering USM clusters in $ENV_ID"
  for kind in connect-clusters kafka-clusters; do
    for id in $(ccloud_api GET "/usm/v1/$kind?environment=$ENV_ID" | jq -r '.data[].id'); do
      echo "  $kind/$id"
      ccloud_api DELETE "/usm/v1/$kind/$id?environment=$ENV_ID" >/dev/null || true
    done
  done
fi

if kubectl get ns "$NS" >/dev/null 2>&1; then
  log "deleting Confluent Cloud workloads (console proxy, consumers, schema exporter, cluster link, cloud topic)"
  kubectl delete -f "$REPO_ROOT/k8s/ccloud/60-console-proxy.yaml" --ignore-not-found || true
  kubectl delete -f "$REPO_ROOT/k8s/ccloud/50-cloud-avro-consumer.yaml" --ignore-not-found || true
  kubectl delete -f "$REPO_ROOT/k8s/ccloud/30-cloud-consumer.yaml" --ignore-not-found || true
  kubectl -n "$NS" delete schemaexporter cp-to-cloud --ignore-not-found || true
  # Source side first, then destination side.
  kubectl -n "$NS" delete clusterlink cp-to-cloud-source --ignore-not-found || true
  kubectl -n "$NS" delete clusterlink cp-to-cloud-dest --ignore-not-found || true
  kubectl -n "$NS" delete kafkatopic ccloud-orders --ignore-not-found || true
  kubectl -n "$NS" delete kafkarestclass krc-cloud krc-cfk --ignore-not-found || true

  log "deleting Confluent Platform"
  if kubectl get ns flink >/dev/null 2>&1; then
    kubectl -n flink delete flinkdeployment --all --ignore-not-found || true
    # The FlinkEnvironment finalizer asks CMF to delete the environment, which
    # CMF refuses while it still holds compute pools/statements, so the delete
    # hangs forever. CMF and its database are removed next anyway: give it a
    # moment, then drop the finalizer.
    kubectl -n flink delete flinkenvironment --all --ignore-not-found --wait=false || true
    sleep 20
    for fe in $(kubectl -n flink get flinkenvironment -o name 2>/dev/null); do
      kubectl -n flink patch "$fe" --type=merge -p '{"metadata":{"finalizers":null}}' || true
    done
    kubectl delete -f "$REPO_ROOT/k8s/flink/cfk-flink.yaml" --ignore-not-found || true
    helm -n flink uninstall cmf cp-flink-kubernetes-operator 2>/dev/null || true
    kubectl -n flink delete pvc --all --wait=true || true
  fi
  kubectl delete -f "$REPO_ROOT/k8s/apps/" --ignore-not-found || true
  kubectl -n "$NS" delete connector --all --ignore-not-found || true
  for f in $(ls -r "$REPO_ROOT"/k8s/cfk/[1-9]*.yaml); do
    kubectl delete -f "$f" --ignore-not-found || true
  done
  kubectl -n "$NS" delete pvc --all --wait=true || true
fi

log "terraform destroy"
terraform -chdir="$TF_DIR" destroy -input=false -auto-approve
rm -f "$KUBECONFIG"
