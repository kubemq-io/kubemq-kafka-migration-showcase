#!/usr/bin/env bash
#
# operator-cidr.sh — detect this laptop's public IPv4 address and write it as a /32 into
# terraform/$CLOUD/infra/operator.auto.tfvars. That /32 is the ONLY source the firewall
# admits for SSH, the Kafka EXTERNAL listener (9094) and the Kubernetes API.
#
# Usage: CLOUD=gcp|aws scripts/operator-cidr.sh          (or: scripts/operator-cidr.sh gcp)
#   MYIP=x.x.x.x  overrides detection (VPN, corporate egress, CI).
#
# Re-run after your IP changes, then `terraform apply` in terraform/$CLOUD/infra.
# Never writes 0.0.0.0/0; Terraform's validation refuses it as well.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CLOUD="${1:-${CLOUD:-}}"
require_cloud cidr
OUT="$ROOT/terraform/$CLOUD/infra/operator.auto.tfvars"

# -4 is load-bearing: on a dual-stack uplink these services answer with the IPv6 address,
# and the firewall source ranges are IPv4 /32s.
IP="${MYIP:-}"
if [ -z "$IP" ]; then
  IP="$(curl -4 -sS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  [ -n "$IP" ] || IP="$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
fi
IP="$(printf '%s' "$IP" | tr -d '[:space:]')"
if ! [[ "$IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
  die "could not detect a public IPv4 address (got '${IP:-<empty>}'). Set MYIP=x.x.x.x and re-run."
fi
for o in "${BASH_REMATCH[@]:1}"; do
  [ "$o" -le 255 ] || die "invalid IPv4 octet in '$IP'"
done
[ "$IP" != "0.0.0.0" ] || die "refusing 0.0.0.0"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<TFV
# Written by scripts/operator-cidr.sh $(date -u +%Y-%m-%dT%H:%M:%SZ). Gitignored. Re-run the script after an IP change.
operator_cidr = "$IP/32"
TFV
say "✅ operator_cidr = \"$IP/32\"  → $OUT"
