#!/usr/bin/env bash
#
# seed.sh — cross-compile tools/seed for linux/amd64, ship it to the driver VM over SSH,
# and load the Kafka cluster over the VPC: 10 topics x 6 partitions, replication 3,
# keyed + headered records, 3 consumer groups committed at 100% / 50% / 10%.
# Then verify. Any produce error or short count is a FAIL.
#
# Usage: scripts/seed.sh [--records N] [--size BYTES] [--topics N] [--partitions N] [--recreate]
#                        [-- extra seeder flags]
#   RECORDS env var (default 500000) is the record count unless --records is given.
#   Full-size run: RECORDS=5000000.
#
# Refuses to re-seed an already-seeded cluster unless --recreate is passed (the seeder
# enforces this; the error is surfaced here with the fix).
#
# On success writes .rig/seed.env: RECORDS, TOPICS, PARTITIONS, SIZE, SEEDED_AT.
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RECORDS="${RECORDS:-500000}"
SIZE=1024; TOPICS=10; PARTITIONS=6; RECREATE=0
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --records)    RECORDS="$2"; shift 2 ;;
    --size)       SIZE="$2"; shift 2 ;;
    --topics)     TOPICS="$2"; shift 2 ;;
    --partitions) PARTITIONS="$2"; shift 2 ;;
    --recreate)   RECREATE=1; shift ;;
    --)           shift; EXTRA+=("$@"); break ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done
[[ "$RECORDS" =~ ^[0-9]+$ ]] || die "--records must be an integer (got '$RECORDS')"

load_rig_env --without-seed   # a previous run's seed.env must not override the flags above
: "${KAFKA_BOOTSTRAP_INTERNAL:?missing in .rig/env}"
command -v go >/dev/null 2>&1 || die "go toolchain not found (needed to cross-compile tools/seed)"

SEED_BIN=/opt/kafka-showcase/seed
ARGS=(-records "$RECORDS" -size "$SIZE" -topics "$TOPICS" -partitions "$PARTITIONS" -rf 3 -min-isr 2)
[ "$RECREATE" = 1 ] && ARGS+=(-recreate)
ARGS+=("${EXTRA[@]}")

say "== building seeder (linux/amd64) =="
( cd "$ROOT/tools/seed" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$RIG_DIR/seed" . ) || die "go build failed"

say "== shipping seeder to the driver ($DRIVER_SSH) =="
wait_driver_ssh
# base64 over stdin: survives a pseudo-terminal (gcloud may allocate one) that would
# mangle raw binary; gzip keeps the transfer to a few MB.
gzip -c "$RIG_DIR/seed" | base64 \
  | driver_ssh "set -e; base64 -d | gunzip > /tmp/seed.upload; sudo mkdir -p $(dirname "$SEED_BIN"); sudo install -m 0755 /tmp/seed.upload $SEED_BIN; rm -f /tmp/seed.upload; test -x $SEED_BIN" \
  || die "could not copy the seeder to the driver"

say "== seeding via $KAFKA_BOOTSTRAP_INTERNAL: $RECORDS records x $SIZE B, $TOPICS topics x $PARTITIONS partitions, rf=3 =="
LOG="$RIG_DIR/seed-$(date -u +%Y%m%dT%H%M%SZ).log"
driver_ssh "$SEED_BIN -brokers $KAFKA_BOOTSTRAP_INTERNAL -mode seed ${ARGS[*]}" 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"
say "(log: $LOG)"

if [ "$RC" != 0 ]; then
  if grep -q 'topics already exist' "$LOG"; then
    die "Kafka is already seeded. Re-run with --recreate to wipe the topics and seed again, or 'make status' to verify what is there."
  fi
  die "seeding failed (exit $RC) — see ⛔/FAIL lines above"
fi

cat > "$RIG_DIR/seed.env" <<ENV
# Written by scripts/seed.sh — source me. Consumed by scripts/kafka/verify.sh and the prompts.
RECORDS=$RECORDS
TOPICS=$TOPICS
PARTITIONS=$PARTITIONS
SIZE=$SIZE
SEEDED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENV
say "✅ seeded; wrote $RIG_DIR/seed.env"
