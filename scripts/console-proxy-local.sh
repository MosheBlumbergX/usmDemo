#!/usr/bin/env bash
# Laptop side of scripts/console.sh (make console), run with sudo:
#   sudo scripts/console-proxy-local.sh up     /etc/hosts entries + pf 443 -> 18443
#   sudo scripts/console-proxy-local.sh down   undo both
# The redirect is inserted into the main pf ruleset (after Apple's rdr-anchor)
# rather than an anchor, so it works even if /etc/pf.conf was never loaded.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
tf_out() { sudo -u "${SUDO_USER:-root}" terraform -chdir="$TF_DIR" output -raw "$1"; }

RULE='rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port 18443'

# Drop our entries (and the bare "127.0.0.1" left by a wrapped paste).
sed -i '' -e '/# console-proxy$/d' -e '/^127\.0\.0\.1[[:space:]]*$/d' /etc/hosts

case "${1:-up}" in
  up)
    suffix="$(tf_out ccloud_access_point_dns_domain | sed 's/\.accesspoint\.confluent\.cloud$/.accesspoint.glb.confluent.cloud/')"
    for id in "$(tf_out ccloud_cluster_id)" "$(tf_out ccloud_schema_registry_id)"; do
      echo "127.0.0.1 $id-$suffix  # console-proxy" >>/etc/hosts
    done
    pfctl -a com.apple/console-proxy -F all 2>/dev/null || true
    sed "/^rdr-anchor \"com.apple\/\*\"/a\\
$RULE
" /etc/pf.conf | pfctl -f -
    pfctl -E 2>/dev/null || true
    grep console-proxy /etc/hosts
    pfctl -s nat 2>/dev/null | grep 18443
    ;;
  down)
    pfctl -a com.apple/console-proxy -F all 2>/dev/null || true
    pfctl -f /etc/pf.conf
    echo "removed hosts entries and pf redirect"
    ;;
  *) echo "usage: $0 up|down" >&2; exit 1 ;;
esac
