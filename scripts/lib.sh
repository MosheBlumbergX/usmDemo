#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

# Dedicated kubeconfig so we never touch ~/.kube/config.
export KUBECONFIG="$REPO_ROOT/.kubeconfig"

if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.env"
  set +a
fi

: "${CONFLUENT_CLOUD_API_KEY:?Set CONFLUENT_CLOUD_API_KEY in .env (see .env.example)}"
: "${CONFLUENT_CLOUD_API_SECRET:?Set CONFLUENT_CLOUD_API_SECRET in .env (see .env.example)}"

# Pass optional .env overrides through to Terraform.
[[ -n "${DEMO_REGION:-}" ]] && export TF_VAR_region="$DEMO_REGION"
[[ -n "${DEMO_NAME:-}" ]] && export TF_VAR_name="$DEMO_NAME"

CFK_CHART_VERSION="${CFK_CHART_VERSION:-0.1718.99}" # CFK 3.3.1
NS=usm

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null || { echo "missing required tool: $bin" >&2; exit 1; }
  done
}

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }
tf_out_json() { terraform -chdir="$TF_DIR" output -json "$1"; }

# Confluent Cloud REST call authenticated with the Cloud API key from .env.
ccloud_api() {
  local method=$1 path=$2; shift 2
  curl -sS -u "$CONFLUENT_CLOUD_API_KEY:$CONFLUENT_CLOUD_API_SECRET" \
    -X "$method" -H 'Content-Type: application/json' \
    "https://api.confluent.cloud$path" "$@"
}

# Render a manifest, substituting only the listed variables (keeps any other
# literal "$" intact), and apply it.
apply_rendered() {
  local file=$1
  envsubst '${CCLOUD_ENV_ID} ${USM_FRONTDOOR_URL} ${S3_BUCKET} ${AWS_REGION} ${CCLOUD_CLUSTER_ID} ${CCLOUD_BOOTSTRAP} ${CCLOUD_REST_ENDPOINT} ${CP_CLUSTER_ID} ${CCLOUD_SR_URL}' <"$file" | kubectl apply -f -
}

# Idempotent "create or update" for a generic secret.
apply_secret() {
  local name=$1; shift
  kubectl -n "$NS" create secret generic "$name" "$@" --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -
}

# Background kubectl port-forward that restarts if it drops (pod restart,
# network blip). Runs in its own process group; .<name>.pid holds the group
# leader so pf_stop kills the lot. Log in .<name>.log. No-op if already running.
pf_start() { # name target local:remote [namespace]
  local name=$1 target=$2 ports=$3 ns=${4:-$NS}
  local pidfile="$REPO_ROOT/.$name.pid" logfile="$REPO_ROOT/.$name.log"
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then return 0; fi
  log "starting port-forward localhost:${ports%%:*} -> $target (log: $logfile)"
  set -m
  nohup bash -c "while true; do
    kubectl -n $ns port-forward --address 127.0.0.1 $target $ports
    sleep 2
  done" >"$logfile" 2>&1 &
  echo $! >"$pidfile"
  set +m
  local rc
  for _ in {1..15}; do # wait until the port accepts connections (curl 7 = refused)
    rc=0; curl -s -m 1 "http://127.0.0.1:${ports%%:*}" >/dev/null 2>&1 || rc=$?
    ((rc != 7)) && break
    sleep 1
  done
}

pf_stop() { # name
  local pidfile="$REPO_ROOT/.$1.pid"
  if [[ -f "$pidfile" ]]; then
    kill -- "-$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
}

wait_for() { # kind name [timeout] [expected] [jsonpath]
  local kind=$1 name=$2 timeout=${3:-900} want=${4:-RUNNING} path=${5:-'{.status.phase}'}
  log "waiting for $kind/$name to be $want (timeout ${timeout}s)"
  local end=$((SECONDS + timeout))
  until [[ "$(kubectl -n "$NS" get "$kind" "$name" -o jsonpath="$path" 2>/dev/null)" == "$want" ]]; do
    if ((SECONDS > end)); then
      warn "$kind/$name not $want after ${timeout}s"
      kubectl -n "$NS" get "$kind" "$name" -o yaml | tail -40 || true
      return 1
    fi
    sleep 10
  done
}
