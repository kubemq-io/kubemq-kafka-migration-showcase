#!/usr/bin/env bash
#
# write-env.sh — read `terraform output -json` from terraform/$CLOUD/infra and
# terraform/$CLOUD/k8s-addons and write .rig/env, the one file every prompt and
# script sources for addresses, commands and names.
#
# Usage: CLOUD=gcp|aws scripts/write-env.sh      (or: scripts/write-env.sh gcp)
#   TF=tofu to use OpenTofu instead of terraform (auto-detected when unset).
#
# k8s-addons is optional: when it has no state yet, LICENSE_SECRET / TLS_SECRET are
# left empty and a warning is printed. Re-run after `make addons-up`.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CLOUD="${1:-${CLOUD:-}}"
require_cloud env
TF="$(tf_bin)"
INFRA="$ROOT/terraform/$CLOUD/infra"
ADDONS="$ROOT/terraform/$CLOUD/k8s-addons"
command -v jq >/dev/null 2>&1 || die "jq is required"

say "== reading outputs from $INFRA ($TF) =="
INFRA_JSON="$("$TF" -chdir="$INFRA" output -json 2>/dev/null)" || die "terraform output failed in $INFRA — has 'make CLOUD=$CLOUD infra-up' run?"
[ "$INFRA_JSON" != "{}" ] || die "no outputs in $INFRA state — has 'make CLOUD=$CLOUD infra-up' run?"

ADDONS_JSON="{}"
if [ -d "$ADDONS" ]; then
  if ! ADDONS_JSON="$("$TF" -chdir="$ADDONS" output -json 2>/dev/null)" || [ "$ADDONS_JSON" = "{}" ]; then
    warn "no outputs in $ADDONS (not applied yet) — LICENSE_SECRET/TLS_SECRET left empty; re-run after 'make CLOUD=$CLOUD addons-up'"
    ADDONS_JSON="{}"
  fi
fi

out() { # out <json> <key> [required]
  local v
  v="$(printf '%s' "$1" | jq -r --arg k "$2" '.[$k].value // empty | if type=="string" then . else tojson end')"
  if [ -z "$v" ] && [ "${3:-}" = required ]; then die "output '$2' missing from infra state (CONTRACT requires it)"; fi
  printf '%s' "$v"
}

KAFKA_BOOTSTRAP_EXTERNAL="$(out "$INFRA_JSON" kafka_bootstrap_external required)"
KAFKA_BOOTSTRAP_INTERNAL="$(out "$INFRA_JSON" kafka_bootstrap_internal required)"
DRIVER_SSH="$(out "$INFRA_JSON" driver_ssh_command required)"
DRIVER_IP="$(out "$INFRA_JSON" driver_public_ip required)"
KUBECONFIG_CMD="$(out "$INFRA_JSON" kubeconfig_command required)"
CLUSTER_NAME="$(out "$INFRA_JSON" cluster_name required)"
STORAGE_CLASS="$(out "$INFRA_JSON" storage_class required)"
HOURLY_COST="$(out "$INFRA_JSON" hourly_cost_estimate required)"
KUBEMQ_NAMESPACE="$(out "$ADDONS_JSON" kubemq_namespace)"
[ -n "$KUBEMQ_NAMESPACE" ] || KUBEMQ_NAMESPACE="$(out "$INFRA_JSON" kubemq_namespace)"
[ -n "$KUBEMQ_NAMESPACE" ] || KUBEMQ_NAMESPACE=kubemq
LICENSE_SECRET="$(out "$ADDONS_JSON" license_secret_name)"
TLS_SECRET="$(out "$ADDONS_JSON" tls_secret_name)"

# Every value is single-quoted: Terraform outputs are free text (cost strings, commands)
# and must not be word-split or expanded when .rig/env is sourced.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
{
  printf '# Written by scripts/write-env.sh %s from terraform outputs — source me, never edit.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s=%s\n' \
    CLOUD                    "$(sq "$CLOUD")" \
    KAFKA_BOOTSTRAP_EXTERNAL "$(sq "$KAFKA_BOOTSTRAP_EXTERNAL")" \
    KAFKA_BOOTSTRAP_INTERNAL "$(sq "$KAFKA_BOOTSTRAP_INTERNAL")" \
    DRIVER_SSH               "$(sq "$DRIVER_SSH")" \
    DRIVER_IP                "$(sq "$DRIVER_IP")" \
    KUBECONFIG_CMD           "$(sq "$KUBECONFIG_CMD")" \
    CLUSTER_NAME             "$(sq "$CLUSTER_NAME")" \
    KUBEMQ_NAMESPACE         "$(sq "$KUBEMQ_NAMESPACE")" \
    STORAGE_CLASS            "$(sq "$STORAGE_CLASS")" \
    LICENSE_SECRET           "$(sq "$LICENSE_SECRET")" \
    TLS_SECRET               "$(sq "$TLS_SECRET")" \
    HOURLY_COST              "$(sq "$HOURLY_COST")"
} > "$RIG_DIR/env"
say "✅ wrote $RIG_DIR/env:"
sed 's/^/   /' "$RIG_DIR/env"
