#!/usr/bin/env bash
#
# verify-teardown.sh — after `terraform destroy`, RE-QUERY the cloud account and prove
# nothing from this showcase is still billing. The re-query is the point: "destroy said
# ok" is not "nothing is left".
#
# Usage: CLOUD=gcp|aws scripts/verify-teardown.sh      (or: scripts/verify-teardown.sh gcp)
#   GCP: PROJECT (or project_id tfvar, or gcloud config), REGION optional
#   AWS: REGION (or AWS_REGION, or region tfvar, or aws configure)
#   NAME_PREFIX (default kmq-showcase, or name_prefix tfvar); CLUSTER_NAME from .rig/env if present
#
# Looks for resources carrying the showcase label/tag (showcase=kafka-migration), the
# name prefix, or Kubernetes-created markers (goog-gke-volume / kubernetes.io/cluster/*):
#   GCP: instances, disks, addresses, firewall rules, forwarding rules, routers (Cloud NAT),
#        GKE clusters, VPC networks
#   AWS: instances, EBS volumes, Elastic IPs, security groups, load balancers (v2 + classic),
#        NAT gateways, EKS clusters, VPCs
#
# Exit 0 and print exactly `TEARDOWN VERIFIED CLEAN` only when every category is empty.
# Otherwise exit 1 and list each leftover with an hourly cost hint.
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CLOUD="${1:-${CLOUD:-}}"
require_cloud verify-teardown
INFRA="$ROOT/terraform/$CLOUD/infra"
LABEL_KEY=showcase; LABEL_VAL=kafka-migration
PREFIX="${NAME_PREFIX:-}"
[ -n "$PREFIX" ] || PREFIX="$(tfvar "$INFRA" name_prefix || true)"
[ -n "$PREFIX" ] || PREFIX="kmq-showcase"
CLUSTER="${CLUSTER_NAME:-}"
if [ -z "$CLUSTER" ] && [ -f "$RIG_DIR/env" ]; then
  CLUSTER="$(grep -E '^CLUSTER_NAME=' "$RIG_DIR/env" | cut -d= -f2- | tr -d "\"'" || true)"
fi

# Every cloud query goes through q: a query that ERRORS (expired credentials, missing
# permission, wrong project) must not read as "0 leftovers". Failures are collected in a
# file because the queries run inside $(...) subshells.
QFAIL="$(mktemp)"; QERR="$(mktemp)"
trap 'rm -f "$QFAIL" "$QERR"' EXIT
q() { "$@" 2>>"$QERR" || printf '%s\n' "$*" >>"$QFAIL"; }

LEFT=0
report() { # report <category> <cost-hint> <lines>
  local n=0
  if [ -n "$3" ]; then n="$(printf '%s\n' "$3" | grep -c .)"; fi
  if [ "$n" -eq 0 ]; then
    printf '  ✅ %-28s 0\n' "$1"
  else
    printf '  ⛔ %-28s %d   (%s)\n' "$1" "$n" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
    LEFT=$((LEFT + n))
  fi
}
uniq_lines() { grep -v '^$' | sort -u; }

if [ "$CLOUD" = gcp ]; then
  command -v gcloud >/dev/null 2>&1 || die "gcloud not found"
  PROJECT="${PROJECT:-${GOOGLE_CLOUD_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}}"
  [ -n "$PROJECT" ] || PROJECT="$(tfvar "$INFRA" project_id || true)"
  [ -n "$PROJECT" ] || PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  [ -n "$PROJECT" ] || die "GCP project unknown: set PROJECT=<id>"
  G=(gcloud --project "$PROJECT" --quiet)
  OURS="labels.$LABEL_KEY=$LABEL_VAL OR name~^$PREFIX"
  [ -n "$CLUSTER" ] && OURS="$OURS OR name~^gke-$CLUSTER- OR labels.goog-k8s-cluster-name=$CLUSTER OR resourceLabels.goog-k8s-cluster-name=$CLUSTER"
  say "== re-query project $PROJECT (prefix $PREFIX, label $LABEL_KEY=$LABEL_VAL${CLUSTER:+, cluster $CLUSTER}) =="

  report "VM instances" "n2-standard-8 ≈ \$0.39/h each, n2-standard-4 ≈ \$0.19/h" \
    "$(q "${G[@]}" compute instances list --filter="$OURS" --format='value(name,zone.basename(),machineType.basename(),status)' | uniq_lines)"
  report "persistent disks" "pd-balanced ≈ \$0.10/GB-month; boot disks and PVC disks" \
    "$(q "${G[@]}" compute disks list --filter="$OURS OR labels.goog-gke-volume:*" --format='value(name,zone.basename(),sizeGb,type.basename())' | uniq_lines)"
  report "static addresses" "unused reserved address ≈ \$0.01/h each" \
    "$(q "${G[@]}" compute addresses list --filter="$OURS" --format='value(name,region.basename(),address,status)' | uniq_lines)"
  report "firewall rules" "free, but blocks re-create and widens exposure" \
    "$(q "${G[@]}" compute firewall-rules list --filter="name~^$PREFIX OR network~$PREFIX${CLUSTER:+ OR name~^gke-$CLUSTER-}" --format='value(name,network.basename())' | uniq_lines)"
  # GKE Service load balancers are named a<hash>; their only marker is the description
  # {"kubernetes.io/service-name":"ns/svc"}. Listed separately as a warning (not a hard
  # leftover) because a shared project may host other clusters' Services.
  report "forwarding rules (LBs)" "load balancer ≈ \$0.025/h + data" \
    "$(q "${G[@]}" compute forwarding-rules list --filter="name~^$PREFIX OR network~$PREFIX" --format='value(name,region.basename(),IPAddress)' | uniq_lines)"
  K8S_FWD="$(q "${G[@]}" compute forwarding-rules list --filter="description~kubernetes.io/service-name" --format='value(name,region.basename(),IPAddress,description)' | uniq_lines)"
  report "cloud routers / NAT" "Cloud NAT ≈ \$0.044/h per gateway + data" \
    "$(q "${G[@]}" compute routers list --filter="name~^$PREFIX OR network~$PREFIX" --format='value(name,region.basename(),network.basename())' | uniq_lines)"
  report "GKE clusters" "control plane ≈ \$0.10/h + nodes" \
    "$(q "${G[@]}" container clusters list --filter="name~^$PREFIX OR resourceLabels.$LABEL_KEY=$LABEL_VAL${CLUSTER:+ OR name=$CLUSTER}" --format='value(name,location,status)' | uniq_lines)"
  report "VPC networks" "free, but blocks re-create" \
    "$(q "${G[@]}" compute networks list --filter="name~^$PREFIX" --format='value(name)' | uniq_lines)"
  if [ -n "$K8S_FWD" ]; then
    echo
    warn "Kubernetes Service load balancers still exist in this project (≈ \$0.025/h each). If any belongs to the showcase cluster it is a leftover; verify by hand:"
    printf '%s\n' "$K8S_FWD" | sed 's/^/        /'
  fi

else
  command -v aws >/dev/null 2>&1 || die "aws cli not found"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
  [ -n "$REGION" ] || REGION="$(tfvar "$INFRA" region || true)"
  [ -n "$REGION" ] || REGION="$(aws configure get region 2>/dev/null || true)"
  [ -n "$REGION" ] || die "AWS region unknown: set REGION=<region>"
  A=(aws --region "$REGION" --output json)
  TAG_SHOWCASE="Name=tag:$LABEL_KEY,Values=$LABEL_VAL"
  TAG_NAME="Name=tag:Name,Values=$PREFIX*"
  K8S_KEY=""; [ -n "$CLUSTER" ] && K8S_KEY="Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER"
  say "== re-query region $REGION (prefix $PREFIX, tag $LABEL_KEY=$LABEL_VAL${CLUSTER:+, cluster $CLUSTER}) =="

  ec2q() { # ec2q <subcommand> <jq> <filters...>
    local sub="$1" q="$2"; shift 2
    q "${A[@]}" ec2 "$sub" --filters "$@" | jq -r "$q"
  }
  # Filters within one call are ANDed; run one call per marker and union the results.
  union() { # union <subcommand> <jq> <state-filter> <marker-filters...>
    local sub="$1" q="$2" st="$3"; shift 3
    local f
    { for f in "$@"; do [ -n "$f" ] && ec2q "$sub" "$q" "$st" "$f"; done; } | uniq_lines
  }

  report "EC2 instances" "i4i.2xlarge ≈ \$0.69/h, m6i.xlarge ≈ \$0.19/h each" \
    "$(union describe-instances '.Reservations[].Instances[] | "\(.InstanceId) \(.InstanceType) \(.State.Name) \((.Tags//[])|map(select(.Key=="Name"))[0].Value // "-")"' \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" "$TAG_SHOWCASE" "$TAG_NAME" "$K8S_KEY")"
  report "EBS volumes" "gp3 ≈ \$0.08/GB-month; PVC volumes survive cluster deletion" \
    "$(union describe-volumes '.Volumes[] | "\(.VolumeId) \(.Size)GiB \(.State)"' \
        "Name=status,Values=creating,available,in-use" "$TAG_SHOWCASE" "$TAG_NAME" "$K8S_KEY" "Name=tag-key,Values=ebs.csi.aws.com/cluster" "Name=tag-key,Values=kubernetes.io/created-for/pvc/name")"
  report "Elastic IPs" "unassociated EIP ≈ \$0.005/h each" \
    "$(union describe-addresses '.Addresses[] | "\(.AllocationId) \(.PublicIp) \(if .AssociationId then "associated" else "UNASSOCIATED" end)"' \
        "Name=domain,Values=vpc" "$TAG_SHOWCASE" "$TAG_NAME" "$K8S_KEY")"
  OTHER_EIPS="$(ec2q describe-addresses '.Addresses[] | select(.AssociationId==null) | "\(.AllocationId) \(.PublicIp)"' "Name=domain,Values=vpc" | uniq_lines)"
  report "security groups" "free, but blocks VPC deletion" \
    "$(union describe-security-groups '.SecurityGroups[] | "\(.GroupId) \(.GroupName)"' \
        "Name=group-name,Values=*" "$TAG_SHOWCASE" "Name=group-name,Values=$PREFIX*" "$K8S_KEY" "${CLUSTER:+Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER}" "${CLUSTER:+Name=tag:aws:eks:cluster-name,Values=$CLUSTER}")"
  lbs_v2() {
    local arns arn tags
    arns="$(q "${A[@]}" elbv2 describe-load-balancers | jq -r '.LoadBalancers[].LoadBalancerArn')"
    for arn in $arns; do
      tags="$(q "${A[@]}" elbv2 describe-tags --resource-arns "$arn" | jq -r '.TagDescriptions[0].Tags[] | "\(.Key)=\(.Value)"')"
      if printf '%s\n' "$tags" | grep -qE "^$LABEL_KEY=$LABEL_VAL$|^kubernetes.io/cluster/${CLUSTER:-__none__}=|^elbv2.k8s.aws/cluster=${CLUSTER:-__none__}$" || [[ "$arn" == *"/$PREFIX"* ]]; then
        printf '%s\n' "$arn"
      fi
    done
  }
  lbs_classic() {
    local names n tags
    names="$(q "${A[@]}" elb describe-load-balancers | jq -r '.LoadBalancerDescriptions[].LoadBalancerName')"
    for n in $names; do
      tags="$(q "${A[@]}" elb describe-tags --load-balancer-names "$n" | jq -r '.TagDescriptions[0].Tags[] | "\(.Key)=\(.Value)"')"
      if printf '%s\n' "$tags" | grep -qE "^$LABEL_KEY=$LABEL_VAL$|^kubernetes.io/cluster/${CLUSTER:-__none__}=" || [[ "$n" == "$PREFIX"* ]]; then
        printf 'classic/%s\n' "$n"
      fi
    done
  }
  report "load balancers (v2+classic)" "NLB/ALB/CLB ≈ \$0.0225/h each + LCU" \
    "$({ lbs_v2; lbs_classic; } | uniq_lines)"
  report "NAT gateways" "≈ \$0.045/h each + data" \
    "$(union describe-nat-gateways '.NatGateways[] | "\(.NatGatewayId) \(.State) \(.VpcId)"' \
        "Name=state,Values=pending,available,deleting" "$TAG_SHOWCASE" "$TAG_NAME")"
  EKS="$(q "${A[@]}" eks list-clusters | jq -r '.clusters[]' | grep -E "^$PREFIX|^${CLUSTER:-__none__}$" | uniq_lines)"
  report "EKS clusters" "control plane ≈ \$0.10/h + nodes" "$EKS"
  report "VPCs" "free, but blocks re-create" \
    "$(union describe-vpcs '.Vpcs[] | "\(.VpcId) \(.CidrBlock)"' "Name=state,Values=available" "$TAG_SHOWCASE" "$TAG_NAME")"
  if [ -n "$OTHER_EIPS" ]; then
    echo
    warn "unassociated Elastic IPs NOT tagged as ours (each bills ≈ \$0.005/h; not counted as a showcase leftover):"
    printf '%s\n' "$OTHER_EIPS" | sed 's/^/        /'
  fi
fi

echo
if [ -s "$QFAIL" ]; then
  printf '⛔ %d cloud query/queries FAILED — the counts above are incomplete and prove nothing:\n' "$(grep -c . "$QFAIL")" >&2
  sed 's/^/        /' "$QFAIL" >&2
  tail -n 5 "$QERR" | sed 's/^/        stderr: /' >&2
  exit 1
fi
if [ "$LEFT" -eq 0 ]; then
  say "TEARDOWN VERIFIED CLEAN"
  exit 0
fi
printf '⛔ TEARDOWN INCOMPLETE — %d resource(s) above are STILL BILLING or block a clean re-create.\n' "$LEFT" >&2
printf '   Re-run "make CLOUD=%s down", or delete them by hand in the console, then re-run this script.\n' "$CLOUD" >&2
exit 1
