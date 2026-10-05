#!/usr/bin/env bash
#
# preflight.sh — check the laptop and the cloud account BEFORE anything is created.
# Prints a PASS/FAIL table and exits 1 on any FAIL, with the fix next to each failure.
#
# Usage: CLOUD=gcp|aws scripts/preflight.sh        (or: scripts/preflight.sh gcp)
#
# Inputs (env, else tfvars in terraform/$CLOUD/infra, else the cloud CLI's config):
#   GCP: PROJECT (or project_id tfvar, or `gcloud config get-value project`)
#        REGION  (or region tfvar, or `gcloud config get-value compute/region`)
#   AWS: REGION  (or AWS_REGION / AWS_DEFAULT_REGION, or region tfvar, or `aws configure get region`)
#
# Checks: tool presence and minimum versions (from versions.env), bash >= 4, IPv4 egress,
# cloud authentication, GCP: required APIs + regional quotas; AWS: vCPU + EIP quotas.
# IAM roles are NOT enumerated (clients often cannot list their own policy); the roles
# needed are listed in docs/00-prerequisites.md.
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_versions

CLOUD="${1:-${CLOUD:-}}"
require_cloud preflight
INFRA="$ROOT/terraform/$CLOUD/infra"

ROWS=()   # "STATUS|check|detail"
FAILS=0
pass() { ROWS+=("PASS|$1|$2"); }
failrow() { ROWS+=("FAIL|$1|$2"); FAILS=$((FAILS+1)); }
warnrow() { ROWS+=("WARN|$1|$2"); }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # ver_ge HAVE MIN
first_num() { grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

# ------------------------------------------------------------------ tools
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then pass "bash >= 4" "bash ${BASH_VERSION%%(*}"; else failrow "bash >= 4" "have $BASH_VERSION; brew install bash"; fi

TFB=""
if command -v terraform >/dev/null 2>&1; then TFB=terraform; elif command -v tofu >/dev/null 2>&1; then TFB=tofu; fi
if [ -n "$TFB" ]; then
  V="$("$TFB" version 2>/dev/null | head -1 | first_num)"
  if ver_ge "$V" "$TERRAFORM_MIN"; then pass "terraform/tofu >= $TERRAFORM_MIN" "$TFB $V"; else failrow "terraform/tofu >= $TERRAFORM_MIN" "$TFB $V is too old"; fi
else
  failrow "terraform/tofu" "install Terraform >= $TERRAFORM_MIN (https://developer.hashicorp.com/terraform/install) or OpenTofu"
fi

if command -v kubectl >/dev/null 2>&1; then pass "kubectl" "$(kubectl version --client 2>/dev/null | first_num)"; else failrow "kubectl" "install kubectl (https://kubernetes.io/docs/tasks/tools/)"; fi
if command -v helm >/dev/null 2>&1; then pass "helm" "$(helm version --short 2>/dev/null | first_num)"; else failrow "helm" "install helm (https://helm.sh/docs/intro/install/) — kmq deploy uses it"; fi
if command -v jq >/dev/null 2>&1; then pass "jq" "$(jq --version 2>/dev/null)"; else failrow "jq" "install jq"; fi
if command -v go >/dev/null 2>&1; then
  V="$(go version | first_num)"
  if ver_ge "$V" "$GO_MIN"; then pass "go >= $GO_MIN" "go $V"; else failrow "go >= $GO_MIN" "go $V is too old (tools/seed needs $GO_MIN)"; fi
else
  failrow "go >= $GO_MIN" "install Go (https://go.dev/dl/) — the seeder is cross-compiled on this machine"
fi
if command -v kcat >/dev/null 2>&1; then
  V="$(kcat -V 2>&1 | first_num)"
  if ver_ge "$V" "$KCAT_MIN"; then pass "kcat >= $KCAT_MIN" "kcat $V"; else warnrow "kcat >= $KCAT_MIN" "kcat $V is old; metadata check may misbehave"; fi
elif command -v nc >/dev/null 2>&1; then
  warnrow "kcat (or nc)" "kcat missing, nc present: verify will only probe ports. brew install kcat / apt install kafkacat"
else
  failrow "kcat (or nc)" "install kcat (brew install kcat) or netcat"
fi
if command -v curl >/dev/null 2>&1; then
  IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then pass "curl -4 public IPv4" "$IP"; else failrow "curl -4 public IPv4" "no IPv4 egress detected; set MYIP=x.x.x.x for operator-cidr.sh"; fi
else
  failrow "curl" "install curl"
fi

# ------------------------------------------------------------------ cloud
if [ "$CLOUD" = gcp ]; then
  if command -v gcloud >/dev/null 2>&1; then pass "gcloud" "$(gcloud version 2>/dev/null | head -1 | first_num)"; else failrow "gcloud" "install the Google Cloud SDK"; fi
  if command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then pass "gke-gcloud-auth-plugin" "present"
  else
    SDK_BIN="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null)/bin"
    if [ -x "$SDK_BIN/gke-gcloud-auth-plugin" ]; then
      failrow "gke-gcloud-auth-plugin" "installed but not on PATH — export PATH=\"$SDK_BIN:\$PATH\" (Homebrew cask does not link components)"
    else
      failrow "gke-gcloud-auth-plugin" "gcloud components install gke-gcloud-auth-plugin"
    fi
  fi
  PROJECT="${PROJECT:-${GOOGLE_CLOUD_PROJECT:-${CLOUDSDK_CORE_PROJECT:-}}}"
  [ -n "$PROJECT" ] || PROJECT="$(tfvar "$INFRA" project_id || true)"
  [ -n "$PROJECT" ] || PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  REGION="${REGION:-}"
  [ -n "$REGION" ] || REGION="$(tfvar "$INFRA" region || true)"
  [ -n "$REGION" ] || REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
  if command -v gcloud >/dev/null 2>&1; then
    ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
    if [ -n "$ACCT" ]; then pass "gcloud auth" "$ACCT"; else failrow "gcloud auth" "gcloud auth login && gcloud auth application-default login"; fi
    if [ -z "$PROJECT" ]; then
      failrow "GCP project" "set PROJECT=<id> or project_id in $INFRA/terraform.tfvars"
    elif gcloud projects describe "$PROJECT" >/dev/null 2>&1; then
      pass "GCP project" "$PROJECT"
    else
      failrow "GCP project" "cannot describe project '$PROJECT' (typo, or no access)"
    fi
    if [ -z "$REGION" ]; then
      failrow "GCP region" "set REGION=<region> or region in $INFRA/terraform.tfvars"
    else
      pass "GCP region" "$REGION"
    fi
    if [ -n "$PROJECT" ]; then
      ENABLED="$(gcloud services list --enabled --project "$PROJECT" --format='value(config.name)' 2>/dev/null)"
      MISSING=()
      for api in compute.googleapis.com container.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com servicenetworking.googleapis.com; do
        printf '%s\n' "$ENABLED" | grep -qx "$api" || MISSING+=("$api")
      done
      if [ "${#MISSING[@]}" -eq 0 ]; then pass "GCP APIs enabled" "compute container iam cloudresourcemanager servicenetworking"
      else failrow "GCP APIs enabled" "run: gcloud services enable ${MISSING[*]} --project $PROJECT"; fi
    fi
    if [ -n "$PROJECT" ] && [ -n "$REGION" ]; then
      RJ="$(gcloud compute regions describe "$REGION" --project "$PROJECT" --format=json 2>/dev/null || true)"
      if [ -n "$RJ" ]; then
        quota() { # quota METRIC MIN
          local avail
          avail="$(printf '%s' "$RJ" | jq -r --arg m "$1" '.quotas[] | select(.metric==$m) | (.limit - .usage) | if . > 1e15 then 999999999 else floor end' 2>/dev/null)"
          if [ -z "$avail" ]; then warnrow "quota $1" "metric not reported in $REGION"; return; fi
          if [ "$avail" -ge "$2" ]; then pass "quota $1 >= $2" "$avail available in $REGION"
          else failrow "quota $1 >= $2" "only $avail available in $REGION — request an increase (IAM & Admin > Quotas)"; fi
        }
        quota CPUS 48
        quota N2_CPUS 48
        quota LOCAL_SSD_TOTAL_GB 1125
        quota IN_USE_ADDRESSES 6
      else
        failrow "GCP quotas" "could not describe region $REGION in $PROJECT (compute API enabled? permissions?)"
      fi
    fi
  fi
else
  if command -v aws >/dev/null 2>&1; then pass "aws cli" "$(aws --version 2>&1 | first_num)"; else failrow "aws cli" "install the AWS CLI v2"; fi
  REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
  [ -n "$REGION" ] || REGION="$(tfvar "$INFRA" region || true)"
  [ -n "$REGION" ] || REGION="$(aws configure get region 2>/dev/null || true)"
  if command -v aws >/dev/null 2>&1; then
    ID="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)"
    if [ -n "$ID" ]; then pass "aws auth" "$ID"; else failrow "aws auth" "aws configure / aws sso login (no valid credentials)"; fi
    if [ -z "$REGION" ]; then failrow "AWS region" "set REGION=<region> (or AWS_REGION, or region in $INFRA/terraform.tfvars)"; else pass "AWS region" "$REGION"; fi
    if [ -n "$ID" ] && [ -n "$REGION" ]; then
      sq() { # sq CODE MIN LABEL
        local v
        v="$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code "$1" --query Quota.Value --output text 2>/dev/null || true)"
        if [ -z "$v" ] || [ "$v" = None ]; then warnrow "quota $3" "could not read quota $1 (servicequotas:GetServiceQuota denied?)"; return; fi
        v="${v%.*}"
        if [ "$v" -ge "$2" ]; then pass "quota $3 >= $2" "$v in $REGION"
        else failrow "quota $3 >= $2" "only $v in $REGION — request an increase: aws service-quotas request-service-quota-increase --service-code ec2 --quota-code $1 --desired-value $2"; fi
      }
      sq L-1216C47A 48 "on-demand Standard vCPUs (L-1216C47A)"
      sq L-0263D0A3 5 "Elastic IPs (L-0263D0A3)"
    fi
  fi
fi

# ------------------------------------------------------------------ table
echo
printf '%-6s %-44s %s\n' STATUS CHECK DETAIL
printf '%-6s %-44s %s\n' ------ -------------------------------------------- ------
for r in "${ROWS[@]}"; do
  IFS='|' read -r s c d <<<"$r"
  printf '%-6s %-44s %s\n' "$s" "$c" "$d"
done
echo
if [ "$FAILS" -gt 0 ]; then die "preflight: $FAILS check(s) FAILED — fix them before 'make CLOUD=$CLOUD infra-up'"; fi
say "✅ preflight passed for CLOUD=$CLOUD"
