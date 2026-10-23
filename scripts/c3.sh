#!/usr/bin/env bash
# Control Center (k8s/cfk/60-controlcenter.yaml) on http://localhost:9021 via a
# background port-forward (restarted if it drops).
#   c3.sh        start (idempotent)
#   c3.sh stop   stop forwarding
source "$(dirname "$0")/lib.sh"
require kubectl curl

if [[ "${1:-}" == "stop" ]]; then
  log "stopping Control Center port-forward"
  pf_stop c3
  exit 0
fi

wait_for controlcenter controlcenter 600
pf_start c3 svc/controlcenter 9021:9021

if [[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost:9021/)" =~ ^[23] ]]; then
  log "Control Center: http://localhost:9021  (stop with: make c3-stop)"
else
  warn "http://localhost:9021 not answering; check $REPO_ROOT/.c3.log"
  exit 1
fi
