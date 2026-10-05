# 04 — Migration bootstrap, probe and target-check

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

- `.rig/env`: `KAFKA_BOOTSTRAP_INTERNAL`, `KAFKA_BOOTSTRAP_EXTERNAL`, `KUBEMQ_NAMESPACE`,
  `STORAGE_CLASS`, `KUBECONFIG_CMD`, `HOURLY_COST`.
- `.rig/kmq.env`: `INSTALLATION_ID`, `ADMIN_USERNAME`.
- `.rig/admin-password` (from prompt 03).

## Preconditions

- Prompt 02 and 03 gates passed.
- `kmq deploy forward --installation "$INSTALLATION_ID" --all` is still running (check
  `kill -0 "$(cat .rig/forward.pid)"`). If not, restart it exactly as in prompt 03 step 6.
  The bootstrap mints the worker's read-only management key through the first loopback
  endpoint and fails with "records no management endpoint" or a connection error otherwise.

## Commands

```
set -a; . .rig/env; . .rig/kmq.env; set +a
eval "$KUBECONFIG_CMD"
kmq skills get core
kmq kafka profile create --help
kmq migrate assess --help
kmq migrate job bootstrap --help
kmq migrate job tool --help
```

### 1. Source profile (internal addresses — what the in-cluster worker dials)

```
kmq kafka profile create kafka-src --bootstrap "$KAFKA_BOOTSTRAP_INTERNAL"
kmq kafka profile inspect kafka-src
```

Do not run `kmq kafka profile validate kafka-src` from this machine: the profile holds the
brokers' VPC-internal addresses, so from a laptop it exits 5 (unreachable), which is expected
and proves nothing. The in-cluster probe below is the validation that matters.

### 2. Read-only assessment of the source (from this machine, external addresses)

```
kmq migrate assess --bootstrap "$KAFKA_BOOTSTRAP_EXTERNAL" --check
```

Reads topic configuration and consumer groups; produces nothing, commits nothing, creates
nothing. `--check` makes it exit non-zero when a topic is `BLOCKED` (compaction, or more than
256 partitions) or when configuration could not be read.

### 3. Bootstrap the worker resources from the installation record

```
kmq migrate job bootstrap \
  --installation "$INSTALLATION_ID" \
  --source-profile kafka-src \
  --out ./migration \
  --storage-class "$STORAGE_CLASS" \
  --admin-username "$ADMIN_USERNAME" --password-stdin --non-interactive \
  < .rig/admin-password
cat migration/bootstrap.json
```

This reads the KubemqCluster, refuses it unless it has at least 3 replicas, the next storage
engine, the Kafka listener not disabled and a plaintext listener, then creates (or verifies,
on a re-run) in namespace `$KUBEMQ_NAMESPACE`:

- Secret `kubemq-migration-credentials` — a freshly minted **read-only** management service key
  and the resolved source credentials (none here). The key never leaves the cluster.
- ConfigMap `kubemq-migration-profiles` — immutable copies of the two Kafka profiles:
  `kafka-src-worker` (your source) and `kubemq-target` (derived: the three pod addresses
  `kubemq-N.kubemq.<namespace>.svc.cluster.local:9092`, plaintext).
- ServiceAccount `kubemq-migration-worker` plus one per cutover stage (unused here).
- PersistentVolumeClaim `kubemq-migration-state` — 20Gi by default (`--state-size`), single
  writer (`ReadWriteOnce`), in your storage class. This is the only resource this prompt bills.
- A short preflight Job that runs `kmq version` inside the worker image and records the build.

It writes `migration/bootstrap.json` (every object with its UID, the worker image **by
digest**, the three management URLs `https://kubemq-N.kubemq.<namespace>.svc.cluster.local:8080`,
and `state_user_id` 65532) and `migration/declaration.json` (the plan template with the
profile names and all `target.*` pins already filled). A re-run with the same values verifies
and changes nothing; a re-run with different values is refused.

### 4. Probe from inside the cluster

```
kmq migrate job tool --bootstrap-file migration/bootstrap.json --tool probe --output migration/probe.json
cat migration/probe.json
```

A one-off Job in the worker image dials the source bootstrap (internal addresses) and lists
brokers and topic count, dials the target Kafka listener and lists its brokers, and reads
`/ready` on each of the three management URLs with the minted read-only key.

### 5. Target-check from inside the cluster

```
kmq migrate job tool --bootstrap-file migration/bootstrap.json --tool target-check --output migration/target-check.json
cat migration/target-check.json
```

Connects to every advertised target broker and reads every member's management API: readiness,
the **running** strict disk-acknowledgement policy, a shared operator deployment identity and
distinct data-volume identities per member.

## Expected green output

- `kmq migrate assess --check` → table headed `Migratable: YES` with 10 topics `[READY]`
  and 3 consumer groups listed; exit 0.
- `kmq migrate job bootstrap` → `"outcome": "ready"`, `"declaration_written": true`,
  `bootstrap.worker_image_pinned: true`, and a `next_steps` list naming the plan and submit
  commands.
- probe → `"outcome": "reachable"`; `source.brokers` has 3 entries and `source.topic_count`
  is at least 10; `target.brokers` has 3 entries; each of
  the three `target_apis` entries has `"reachable": true`, `"ready": true`,
  `"store_ack_policy": "strict"`, `"auth_enabled": true`, `"identity_answered": true`.
- target-check → `"outcome": "ready_at_observation"`, three `nodes` each with
  `"ack_policy": "strict"` and the same `deployment_id`, and a non-empty `coverage_gaps`
  list (it always states what it did not check).

## Expected duration

5–10 minutes. The bootstrap's preflight Job pulls the worker image once (1–3 min); each tool
Job takes about a minute.

## Gate

`migration/bootstrap.json` exists, probe reported `reachable`, target-check reported
`ready_at_observation` with `strict` on all three nodes. Otherwise stop and quote the line.
Resources are billing at `HOURLY_COST`.

## What this proves and does not prove

Proves: the worker network can reach every source broker and every target broker; every
target server **reports** strict disk acknowledgement right now; the worker image matches
this kmq build; the resources later Jobs mount exist with recorded identities.

Does not prove: that the target stays strict during replication (the report records what the
worker observed, not a guarantee), that the data is correct, or that any topic is prepared on
the target — that is prompt 05.
