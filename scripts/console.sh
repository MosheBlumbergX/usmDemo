#!/usr/bin/env bash
# Step 6: let the Confluent Cloud Console in this laptop's browser reach the
# private Enterprise cluster and Schema Registry (mirror topics, cluster link,
# message browser, schemas).
#   browser -> /etc/hosts 127.0.0.1 -> pf 443->18443 -> kubectl port-forward
#     -> console-proxy (k8s/ccloud/60-console-proxy.yaml) -> PrivateLink
#   console.sh        start (idempotent; sudo only if hosts/pf need setting up)
#   console.sh stop   stop forwarding and undo hosts/pf
# macOS won't let a normal user bind 443 and kubectl can't run under sudo (EKS
# credentials live in the user's SSO session), hence the pf redirect.
source "$(dirname "$0")/lib.sh"
require kubectl curl

PORT=18443

if [[ "${1:-}" == "stop" ]]; then
  log "stopping port-forward"
  pf_stop console-proxy
  if grep -q '# console-proxy$' /etc/hosts; then
    log "removing /etc/hosts entries + pf redirect (sudo)"
    sudo "$REPO_ROOT/scripts/console-proxy-local.sh" down
  fi
  exit 0
fi

kafka_host="$(tf_out ccloud_cluster_rest_endpoint | sed -E 's#^https://##; s#:443$##')"
reachable() { [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "https://$kafka_host/")" != 000 ]]; }

kubectl apply -f "$REPO_ROOT/k8s/ccloud/60-console-proxy.yaml" >/dev/null
kubectl -n "$NS" rollout status deploy/console-proxy

pf_start console-proxy deploy/console-proxy "$PORT:443"

if ! reachable; then
  log "setting up /etc/hosts entries + pf redirect 443 -> $PORT (sudo)"
  sudo "$REPO_ROOT/scripts/console-proxy-local.sh" up
fi

if reachable; then
  log "Console can reach the private cluster: https://confluent.cloud/environments/$(tf_out ccloud_environment_id)/clusters/$(tf_out ccloud_cluster_id)"
  echo "  hard-refresh the Console tab; stop with: make console-stop"
else
  warn "https://$kafka_host still unreachable; check $REPO_ROOT/.console-proxy.log"
  exit 1
fi
