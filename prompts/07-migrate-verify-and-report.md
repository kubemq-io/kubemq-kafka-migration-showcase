# 07 — Verify and report

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

This prompt is safe to re-run at any point: each step first checks the current Job state and
only submits the next Job when the previous one has completed. An agent that cannot wait for
long commands should re-run this prompt until the gate passes.

## Inputs

- `.rig/env`, `.rig/kmq.env`.
- `migration/plan.json`, `migration/bootstrap.json`.

## Preconditions

- Prompt 06 gate passed: the replicate Job reports `completed`.

## Commands

```
set -a; . .rig/env; . .rig/kmq.env; set +a
eval "$KUBECONFIG_CMD"
kmq skills get core
kmq migrate job submit --help
kmq migrate job status --help
kmq migrate job logs --help
```

### 1. Verify (reads source and target; same user id, same three target APIs)

```
kmq migrate job status --plan migration/plan.json | jq -c '{operation, state}'
# Only when the output above is {"operation":"replicate","state":"completed"}:
kmq migrate job submit --plan migration/plan.json --bootstrap-file migration/bootstrap.json --operation verify

until out=$(kmq migrate job status --plan migration/plan.json) && echo "$out" | grep -q '"state": *"\(completed\|failed_blocked\|job_deleted\)"'; do
  echo "$out" | jq -c '{operation, state, phase: .progress.phase, freshness: .progress.freshness}'; sleep 20
done
echo "$out"
kmq migrate job logs --plan migration/plan.json --limit-bytes 262144 | jq -r .logs | tail -60
```

Verify re-reads every mapped record from the source and the target over the boundaries the
replicate Job recorded and compares them record by record. Inside the Job it runs with
`--record`, so a successful full comparison is written into the checkpoint as evidence that
the report and any later cutover preflight read.

### 2. Report (offline: reads only the checkpoint; **no** `--target-api`)

```
kmq migrate job status --plan migration/plan.json | jq -c '{operation, state}'
# Only when the output above is {"operation":"verify","state":"completed"}:
kmq migrate job submit --plan migration/plan.json --bootstrap-file migration/bootstrap.json --operation report

until out=$(kmq migrate job status --plan migration/plan.json) && echo "$out" | grep -q '"state": *"\(completed\|failed_blocked\|job_deleted\)"'; do sleep 10; done
echo "$out" | jq '{operation, state, generation, result_location: .progress.result_location}'
GENERATION=$(echo "$out" | jq -r .generation)
```

`report` is an offline checkpoint read: `submit` refuses it with `--target-api`, and
`--bootstrap-file` does not add target APIs for it. The worker writes the report **onto the
state volume** at `/state/report-<generation>.json`; `status` echoes that path as
`progress.result_location` once the Job completes.

### 3. Retrieve `report.json` from the state volume

kmq has no command that copies a file out of the volume (`kmq migrate job logs` returns the
worker's log, not the file). Mount the claim read-only in a short-lived helper pod, running as
the same non-root user id the worker used (65532, from `bootstrap.json`), and copy the file:

```
STATE_PVC=$(jq -r .state_pvc migration/bootstrap.json)
STATE_UID=$(jq -r .state_user_id migration/bootstrap.json)
kubectl -n "$KUBEMQ_NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kmq-report-reader
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: $STATE_UID
    runAsGroup: $STATE_UID
    fsGroup: $STATE_UID
    runAsNonRoot: true
  containers:
  - name: reader
    image: busybox:1.36
    command: ["sh", "-c", "sleep 1800"]
    volumeMounts:
    - name: state
      mountPath: /state
      readOnly: true
  volumes:
  - name: state
    persistentVolumeClaim:
      claimName: $STATE_PVC
      readOnly: true
EOF
kubectl -n "$KUBEMQ_NAMESPACE" wait --for=condition=Ready pod/kmq-report-reader --timeout=5m
kubectl -n "$KUBEMQ_NAMESPACE" exec kmq-report-reader -- cat "/state/report-$GENERATION.json" > migration/report.json
kubectl -n "$KUBEMQ_NAMESPACE" delete pod kmq-report-reader --wait=false
jq '{run_id, plan_hash, generated_at, verification: .verification.status, partitions: (.partitions | length), ack_policy: .ack_policy_observation, database: .database_integrity}' migration/report.json
```

The claim is `ReadWriteOnce`, so the helper pod can only attach while no worker Job is
running; after the report Job completed that is the case. Delete the helper pod before
submitting any further Job. Mounting the volume does not alter the run's recorded identities.

## Expected green output

- verify → `status` ends `"state": "completed"`; the worker log's final JSON has
  `total_mapped` equal to the seeded `RECORDS`, `evidence_recorded: true`, and every
  partition with `unmapped_target_records: 0`, `unverified_target_prefix: false`,
  `unverified_target_tail: false`.
- report → `status` ends `"state": "completed"` with `progress.result_location:
  "/state/report-<generation>.json"`.
- `migration/report.json` → `verification.status: "checkpoint_consistent"` with a non-empty
  `verification.evidence` (the only other value is `"unavailable"`, which means no recorded
  full verification exists), `ack_policy_observation.recorded: true` with `policy: "strict"`,
  `database_integrity.pages_checked: true`, and one `partitions` entry per source partition
  (60) with `"mapped": true`.

Read `docs/05-reading-the-report.md` for every field.

## Expected duration

Verify: 2–5 minutes at the default seed. On the 5,000,000-record fixture, parallel full
verification took about 99 seconds of worker time; observed, not guaranteed. Report: under a
minute. Retrieval: 1–2 minutes (busybox image pull).

## Gate

`migration/report.json` exists, `jq -e '.verification.evidence' migration/report.json` succeeds,
and the verify Job's log showed `total_mapped` equal to `RECORDS`. Otherwise stop and quote
the line. Resources are billing at `HOURLY_COST`; prompt 08 removes them.

## What this proves and does not prove

Proves: every record the plan covered, as replicated, is byte-for-byte present on the target
at its mapped offset; the target reported strict disk acknowledgement when the worker
observed it; the checkpoint database is intact and its hash is recorded.

Does not prove: anything written to the source after the replicate Job's observation; that
consumer groups could resume on the target (no offsets were seeded); application behavior;
cutover readiness; that the target's disk policy stayed strict between observations. The
report "describes its captured scope and evidence; it does not declare a production migration
complete".
