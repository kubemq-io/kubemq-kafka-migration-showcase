#!/usr/bin/env bash
#
# pre-destroy.sh — remove the Kubernetes objects that `terraform destroy` cannot see and
# that would otherwise keep billing after the cluster is gone:
#
#   1. KubeMQCluster custom resources in the KubeMQ namespace (the chart keeps the CR on
#      helm uninstall with helm.sh/resource-policy: keep) — waits for the operator to
#      tear the StatefulSet down
#   2. all PersistentVolumeClaims in the namespace (cloud disks behind them)
#   3. every Service of type LoadBalancer, cluster-wide (cloud load balancers + addresses)
#   4. waits until no PersistentVolume remains in the cluster (disk deletion is async)
#
# Usage: scripts/pre-destroy.sh        (reads .rig/env: KUBECONFIG_CMD, KUBEMQ_NAMESPACE)
#
# If the cluster API is unreachable (already destroyed), prints a warning and exits 0
# so `make down` can continue to terraform destroy; verify-teardown.sh is the real gate.
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_rig_env
: "${KUBECONFIG_CMD:?missing in .rig/env}"
NS="${KUBEMQ_NAMESPACE:-kubemq}"
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

export KUBECONFIG="$RIG_DIR/kubeconfig"
say "== fetching kubeconfig into $KUBECONFIG =="
say "+ $KUBECONFIG_CMD"
if ! bash -c "$KUBECONFIG_CMD" >/dev/null 2>&1; then
  warn "kubeconfig command failed — cluster already gone? Skipping Kubernetes cleanup; verify-teardown.sh will catch leftovers."
  exit 0
fi
if ! kubectl get --raw=/version >/dev/null 2>&1; then
  warn "Kubernetes API unreachable (cluster already destroyed, or your IP changed and the API allow-list blocks you). Skipping; verify-teardown.sh will catch leftovers."
  exit 0
fi

DELETED=()

say "== 0. kmq deploy remove (best effort) =="
if [ -f "$RIG_DIR/kmq.env" ] && command -v kmq >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$RIG_DIR/kmq.env"
  if [ -n "${INSTALLATION_ID:-}" ]; then
    say "+ kmq deploy remove --installation $INSTALLATION_ID"
    kmq deploy remove --installation "$INSTALLATION_ID" || warn "kmq deploy remove returned non-zero (record already removed?); continuing with kubectl cleanup"
  else
    say "   no INSTALLATION_ID in .rig/kmq.env — skipping"
  fi
else
  say "   no .rig/kmq.env or kmq not installed — skipping"
fi

say "== 1. KubeMQCluster resources in namespace $NS =="
if kubectl get crd kubemqclusters.next.kubemq.io >/dev/null 2>&1 || kubectl api-resources 2>/dev/null | grep -qi '^kubemqclusters'; then
  CRS="$(kubectl -n "$NS" get kubemqcluster -o name 2>/dev/null || true)"
  if [ -n "$CRS" ]; then
    printf '%s\n' "$CRS" | sed 's/^/   deleting /'
    kubectl -n "$NS" delete kubemqcluster --all --wait --timeout=10m || warn "kubemqcluster delete did not finish cleanly; continuing"
    while IFS= read -r c; do DELETED+=("$c"); done <<<"$CRS"
  else
    say "   none"
  fi
else
  say "   CRD not installed — nothing to delete"
fi

say "== 1b. finished Jobs and their pods in namespace $NS (completed pods keep PVCs protected) =="
JOBS="$(kubectl -n "$NS" get jobs -o name 2>/dev/null || true)"
if [ -n "$JOBS" ]; then
  printf '%s\n' "$JOBS" | sed 's/^/   deleting /'
  kubectl -n "$NS" delete jobs --all --wait --timeout=5m || warn "job delete did not finish cleanly; continuing"
  while IFS= read -r c; do DELETED+=("$NS/$c"); done <<<"$JOBS"
else
  say "   none"
fi
PODS="$(kubectl -n "$NS" get pods --field-selector=status.phase!=Running -o name 2>/dev/null || true)"
if [ -n "$PODS" ]; then
  printf '%s\n' "$PODS" | sed 's/^/   deleting /'
  kubectl -n "$NS" delete pods --field-selector=status.phase!=Running --wait=false || true
fi

say "== 2. PersistentVolumeClaims in namespace $NS =="
PVCS="$(kubectl -n "$NS" get pvc -o name 2>/dev/null || true)"
if [ -n "$PVCS" ]; then
  printf '%s\n' "$PVCS" | sed 's/^/   deleting /'
  kubectl -n "$NS" delete pvc --all --wait --timeout=5m || warn "pvc delete did not finish cleanly; continuing"
  while IFS= read -r c; do DELETED+=("$NS/$c"); done <<<"$PVCS"
else
  say "   none"
fi

say "== 3. LoadBalancer Services (all namespaces) =="
LBS="$(kubectl get svc -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null || true)"
if [ -n "$LBS" ]; then
  while read -r ns name; do
    [ -n "$name" ] || continue
    say "   deleting service $ns/$name"
    kubectl -n "$ns" delete svc "$name" --wait --timeout=5m || warn "service $ns/$name delete did not finish cleanly"
    DELETED+=("service/$ns/$name")
  done <<<"$LBS"
else
  say "   none"
fi

say "== 4. waiting for PersistentVolumes to disappear (disk deletion is asynchronous) =="
DEADLINE=$((SECONDS + 600))
while :; do
  LEFT="$(kubectl get pv -o name 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${LEFT:-0}" -eq 0 ]; then say "   no PersistentVolumes remain"; break; fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    kubectl get pv 2>/dev/null | sed 's/^/   /'
    warn "$LEFT PersistentVolume(s) still present after 10 min — their disks may survive terraform destroy; verify-teardown.sh will report them"
    break
  fi
  say "   $LEFT PV(s) remaining..."
  sleep 10
done

echo
if [ "${#DELETED[@]}" -eq 0 ]; then
  say "✅ pre-destroy: nothing needed deleting"
else
  say "✅ pre-destroy deleted ${#DELETED[@]} object(s):"
  printf '   %s\n' "${DELETED[@]}"
fi
