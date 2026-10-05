# 06 — Replicate

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

- `.rig/env`, `.rig/kmq.env`, `.rig/seed.env` (`RECORDS`).
- `migration/plan.json`, `migration/bootstrap.json`.

## Preconditions

- Prompt 05 gate passed.
- No Job has been submitted for this plan yet (`kmq migrate job status --plan
  migration/plan.json` reports "no migration Job has been submitted for run ... yet").

## Commands

```
set -a; . .rig/env; . .rig/kmq.env; . .rig/seed.env; set +a
eval "$KUBECONFIG_CMD"
kmq skills get core
kmq migrate job submit --help
kmq migrate job status --help
kmq migrate job logs --help
```

### 1. Submit the replicate Job

```
kmq migrate job submit \
  --plan migration/plan.json \
  --bootstrap-file migration/bootstrap.json \
  --operation replicate
```

`--bootstrap-file` fills every flag it recorded: `--state-pvc kubemq-migration-state`,
`--profiles-configmap kubemq-migration-profiles`, `--service-account kubemq-migration-worker`,
`--credential-secret kubemq-migration-credentials`, `--state-user-id 65532`, and the three
`--target-api https://kubemq-N.kubemq.<namespace>.svc.cluster.local:8080` URLs. You may pass
any of them explicitly; an explicit value wins. The first Job of a run binds the checkpoint on
the state volume to that Linux user id; every later Job must use the same one.

`submit` checks the kmq version against the plan's `worker_kmq_version` and the build the
bootstrap recorded, validates the mounted resources by UID, refuses a second concurrent Job for
the run, and creates one Kubernetes Job named `kmq-<first 16 hex of run id>-<generation>-<operation>`
(observed: `kmq-70de6753bec42fa1-1-replicate`).

Replicate refuses to start unless **every** target server reports `Store.NextAckPolicy=strict`
through its management API, and it records what it observed in the checkpoint.

### 2. Poll until the Job completes

```
until out=$(kmq migrate job status --plan migration/plan.json) && echo "$out" | grep -q '"state": *"\(completed\|failed_blocked\|job_deleted\)"'; do
  echo "$out" | jq -c '{state, progress: {phase: .progress.phase, committed: .progress.committed_records_this_job, freshness: .progress.freshness}}'
  sleep 30
done
echo "$out"
kmq migrate job logs --plan migration/plan.json --limit-bytes 262144 | jq -r .logs | tail -40
```

`status` reads the run's ConfigMaps and the Job object; it never opens the checkpoint. Its
`progress` block comes from a heartbeat the worker publishes: `freshness` is `fresh` when the
heartbeat is under 15 seconds old, `stale` otherwise, `conflict` when the heartbeat and the Job
disagree. `committed_records_this_job` is a bounded observation, not an audit.

## Expected green output

- `submit` → a JSON object naming the Job (`kmq-<run id prefix>-1-replicate`), `"operation": "replicate"`,
  generation 1.
- `status` while running → `"state": "running"`, `progress.phase: "running"`,
  `committed_records_this_job` increasing between polls.
- `status` at the end → `"state": "completed"`, `progress.phase: "completed"`, and
  `next_action` saying to read the result with `kmq migrate job logs`.
- `logs` → the worker's final JSON summary; no line containing `error_code`.

If `state` is `failed_blocked`, the run is blocked until `kmq migrate job recovery-check` and a
manual release record that the old worker is fenced (see `docs/04-migration-flow.md`,
"Recovery after a worker interruption"). Do not delete the ownership ConfigMap or the PVC to
"unstick" it; quote the `next_action` and stop.

## Expected duration

Default seed (500,000 records): allow 3–10 minutes of worker time plus 1–2 minutes of Job
start-up; the reference GCP run finished in about 20 seconds of worker time and about 1 minute
wall clock. The 5,000,000-record run copied in about 1,108 seconds of worker time on our
60-partition fixture (about 4,500 records per second). That number was observed on that
fixture; it is not a capacity guarantee for other topics, networks or targets.

## Gate

`kmq migrate job status --plan migration/plan.json` reports `"state": "completed"`. Otherwise
stop and quote the `next_action`. Resources are billing at `HOURLY_COST`.

## What this proves and does not prove

Proves: every selected record from the source's start offsets up to the high watermarks
observed at run start was produced to the target and acknowledged under strict disk
acknowledgement, and the source-to-target offset mapping is recorded on the state volume.

Does not prove: that the copy is correct — the worker checks acknowledgements, not contents
(that is `verify`, prompt 07). A crash between target acknowledgement and checkpoint commit may
replay up to 32 records per active partition; the mapping, not payload comparison, is what
verify uses to detect that. Nothing was written to any consumer group on the target.
