#!/usr/bin/env bash
#
# verify.sh — Kafka rig status, run from the laptop. Exit 1 if anything is off.
#
#   1. KRaft quorum + broker census, via SSH to the driver VM (inside the VPC)
#   2. laptop reachability of the EXTERNAL listener (kcat -L, or nc port probe)
#   3. if .rig/seed.env exists: run the seeder in verify mode on the driver and
#      assert the exact record count, topics, partitions, replication, group offsets
#
# Usage: scripts/kafka/verify.sh [--records N]   (N overrides the count from .rig/seed.env; 0 = don't check)
#
# Reads .rig/env (DRIVER_SSH, KAFKA_BOOTSTRAP_INTERNAL, KAFKA_BOOTSTRAP_EXTERNAL) and .rig/seed.env.
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

RECORDS_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --records) RECORDS_OVERRIDE="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

load_rig_env
: "${KAFKA_BOOTSTRAP_INTERNAL:?missing in .rig/env}"
: "${KAFKA_BOOTSTRAP_EXTERNAL:?missing in .rig/env}"
EXPECTED_BROKERS=3
FAIL=0
KAFKA_HOME=/opt/kafka
SEED_BIN=/opt/kafka-showcase/seed

say "== KRaft quorum (via driver: $DRIVER_SSH) =="
Q="$(driver_ssh "$KAFKA_HOME/bin/kafka-metadata-quorum.sh --bootstrap-server $KAFKA_BOOTSTRAP_INTERNAL describe --status 2>&1" 2>/dev/null)"
printf '%s\n' "$Q" | grep -E '^(ClusterId|LeaderId|LeaderEpoch|HighWatermark|CurrentVoters|CurrentObservers)' | sed 's/^/   /'
LEADER="$(printf '%s' "$Q" | awk -F': *' '/^LeaderId/{print $2}' | tr -d '\r')"
if [ -n "$LEADER" ] && [ "$LEADER" -gt 0 ] 2>/dev/null; then
  say "   ✅ KRaft leader elected (node $LEADER)"
else
  say "   ⛔ no KRaft leader (quorum output above; is the driver reachable and Kafka up?)"; FAIL=1
fi
N="$(driver_ssh "$KAFKA_HOME/bin/kafka-broker-api-versions.sh --bootstrap-server $KAFKA_BOOTSTRAP_INTERNAL 2>/dev/null | grep -c '(id: '" 2>/dev/null | tr -d '\r ')"
if [ "${N:-0}" -eq "$EXPECTED_BROKERS" ] 2>/dev/null; then
  say "   ✅ $N/$EXPECTED_BROKERS brokers answering on the INTERNAL listener"
else
  say "   ⛔ ${N:-0}/$EXPECTED_BROKERS brokers answering on the INTERNAL listener"; FAIL=1
fi

say "== laptop reachability (EXTERNAL listener: $KAFKA_BOOTSTRAP_EXTERNAL) =="
if command -v kcat >/dev/null 2>&1; then
  META="$(kcat -L -b "$KAFKA_BOOTSTRAP_EXTERNAL" -m 10 2>&1)"
  SEEN="$(printf '%s\n' "$META" | grep -c 'broker [0-9]* at ')"
  if [ "$SEEN" -eq "$EXPECTED_BROKERS" ]; then
    say "   ✅ kcat sees $SEEN brokers"
  else
    say "   ⛔ kcat sees $SEEN/$EXPECTED_BROKERS brokers (public IP changed? run: make CLOUD=$CLOUD cidr && terraform apply)"
    printf '%s\n' "$META" | head -5 | sed 's/^/      /'; FAIL=1
  fi
else
  n=0
  IFS=',' read -r -a HP <<<"$KAFKA_BOOTSTRAP_EXTERNAL"
  for hp in "${HP[@]}"; do
    nc -z -w 5 "${hp%:*}" "${hp##*:}" 2>/dev/null && n=$((n+1))
  done
  if [ "$n" -eq "${#HP[@]}" ]; then
    say "   ✅ tcp open on all $n brokers from this machine (install kcat for a metadata check)"
  else
    say "   ⛔ only $n/${#HP[@]} brokers reachable on their EXTERNAL port from this machine"; FAIL=1
  fi
fi

say "== data (seeder -mode verify on the driver) =="
if [ -f "$RIG_DIR/seed.env" ]; then
  RECORDS_WANT="${RECORDS_OVERRIDE:-${RECORDS:-0}}"
  if driver_ssh "test -x $SEED_BIN" >/dev/null 2>&1; then
    driver_ssh "$SEED_BIN -brokers $KAFKA_BOOTSTRAP_INTERNAL -mode verify -records $RECORDS_WANT -topics ${TOPICS:-10} -partitions ${PARTITIONS:-6}" 2>&1 | sed 's/^/   /'
    [ "${PIPESTATUS[0]}" = 0 ] || { say "   ⛔ seeder verify failed"; FAIL=1; }
  else
    say "   ⛔ $RIG_DIR/seed.env exists but $SEED_BIN is missing on the driver (VM recreated? re-run make seed)"; FAIL=1
  fi
else
  say "   (not seeded yet — .rig/seed.env absent; run: make CLOUD=$CLOUD seed)"
fi

echo
if [ "$FAIL" = 0 ]; then say "KAFKA RIG OK"; exit 0; fi
die "KAFKA RIG HAS PROBLEMS (see ⛔ lines above)"
