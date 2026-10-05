# 02 — Seed Kafka

## Rules for this session (mandatory — read before running anything)

1. **Cost gate.** Before any command that creates cloud resources, print what will be created
   and the hourly cost estimate, then stop and wait for an explicit "yes" from the operator.
   Do not proceed on silence or on a general "go ahead" given earlier in the conversation.
2. **Red is red.** A non-zero exit code, or any output line containing `FAIL`, `⛔`, `failed`,
   `not_ready`, `failed_blocked` or `BLOCKED`, is a failure. Quote the exact line verbatim.
   Never paraphrase a failure as a success or a "minor warning".
3. **Only one sentence means clean.** Only the literal line `TEARDOWN VERIFIED CLEAN`, printed
   by `make CLOUD=$CLOUD verify-teardown`, means nothing is still billing. No other output,
   including a successful `terraform destroy`, means that.
4. **Final message.** Your last message in this session must state whether cloud resources
   are still running and the hourly cost from `.rig/env` (`HOURLY_COST`). If you do not know,
   say "unknown — run prompt 08".
5. **Verify is not cutover.** A passing `verify` certifies that the copied history matches the
   source over the recorded boundaries. It does not certify later source writes, consumer-group
   offsets on the target, application behavior, or a cutover.
6. **Never invent flags.** Before the first `kmq` command of a step, run `kmq skills get core`
   once and `kmq <command> --help` for each command you are about to use. If a flag in this
   prompt does not appear in `--help`, stop and report the difference instead of guessing.
7. **State lives in files, not in memory.** Read cloud state from `.rig/env`, seed state from
   `.rig/seed.env`, installer state from `.rig/kmq.env`. Re-read them at the start of every
   step; never rely on values remembered from earlier in the conversation.

## Inputs

- `.rig/env` (from prompt 01): `CLOUD`, `DRIVER_SSH`, `KAFKA_BOOTSTRAP_INTERNAL`.
- `RECORDS` — optional. Default `500000` (500,000 records total, 50,000 per topic). The full
  run uses `RECORDS=5000000`. Same topics, partitions and groups either way.

## Preconditions

- `make CLOUD=$CLOUD status` exits 0.
- A Go toolchain is installed on this machine (the seeder is cross-compiled here and copied
  to the driver VM).

## Commands

```
set -a; . .rig/env; set +a
make CLOUD=$CLOUD seed                 # default 500,000 records
# or, for the full run:
# make CLOUD=$CLOUD seed RECORDS=5000000
cat .rig/seed.env
```

The seed target creates 10 topics (`orders`, `payments`, `inventory`, `shipments`, `users`,
`clicks`, `notifications`, `audit`, `sensors`, `invoices`) with 6 partitions each (60 total),
produces keyed records of 1,024 bytes with three string headers, and commits offsets for three
consumer groups (`analytics`, `billing`, `archiver`). It then runs the fleet verifier, which
re-reads the high watermarks and compares them with the expected record count.

Running the seed a second time is refused: the seeder exits with `topics already exist` and
`seed.sh` prints the fix. To wipe the ten topics and seed again, run
`make CLOUD=$CLOUD seed SEED_ARGS=--recreate` (same `RECORDS` rules). Do not delete topics by
hand.

## Expected green output

- The seeder's produce summary reads `produced <RECORDS>/<RECORDS> in ... errors=0`.
- The verifier reports 10 topics, 60 partitions, the expected total, and three consumer groups
  with committed offsets, and exits 0.
- `.rig/seed.env` contains `RECORDS=<n>`, `TOPICS=10`, `PARTITIONS=6`, `SEEDED_AT=<time>`.

## Expected duration

Default seed: 3–8 minutes end to end (most of it is the Go cross-compile and copy on the
first run). Full 5,000,000-record seed: 10–20 minutes on the tested machine types.

## Gate

`.rig/seed.env` exists and the verifier exited 0. Otherwise stop and quote the failing line.
Resources are still billing at `HOURLY_COST`.

## What this proves and does not prove

Proves: the source holds a known, countable data set with keys, headers and committed group
offsets — the shape a real migration has to preserve.

Does not prove: anything about KubeMQ, and nothing about a production workload's size or
record mix. The seeded values are synthetic JSON padded to a fixed size.
