# 05 — Prepare target topics and create the plan

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
- `migration/bootstrap.json` and `migration/declaration.json` from prompt 04.
- `kubemq/migration/declaration.example.json` — the scope to copy in (10 topics, 3 groups,
  one placeholder application). Field meanings: `kubemq/migration/README.md`.

## Preconditions

- Prompt 04 gate passed (probe `reachable`, target-check `ready_at_observation`).
- The target topics do not exist yet, or exist empty with the same partition counts. The plan
  refuses a non-empty target partition.

## Commands

```
set -a; . .rig/env; . .rig/kmq.env; . .rig/seed.env; set +a
eval "$KUBECONFIG_CMD"
kmq skills get core
kmq migrate prepare --help
kmq migrate plan --help
kmq migrate job tool --help
```

### 1. Prepare the target topics (in-cluster, preview then apply)

The plan binds each target topic's **creation identity**, so the ten topics must exist on the
target before the plan is made. `kmq migrate prepare` creates ordinary non-compacted topics
with the source's partition count and `retention.ms`, nothing else. It runs as a preview that
prints an immutable preparation plan with a hash, then an apply that requires that exact hash.

Build the request from `bootstrap.json` so the profile names and the three management URLs
match exactly what the worker uses:

```
jq -n --slurpfile b migration/bootstrap.json --slurpfile d kubemq/migration/declaration.example.json '{
  source_profile: $b[0].source_profile,
  target_profile: $b[0].target_profile,
  target_management_context: "",
  target_apis: $b[0].target_api,
  topics: $d[0].topics,
  external_security_reference: "showcase: no users, permissions or quotas exist on the empty target; reviewed by the operator running this prompt"
}' > migration/prepare-request.json

kmq migrate job tool --bootstrap-file migration/bootstrap.json --tool prepare \
  --input migration/prepare-request.json --output migration/prepare-plan.json
jq '[.topic_changes[] | {name, partitions, retention_ms}]' migration/prepare-plan.json
PREPARE_HASH=$(jq -r .hash migration/prepare-plan.json)

kmq migrate job tool --bootstrap-file migration/bootstrap.json --tool prepare \
  --input migration/prepare-plan.json --apply --approve-hash "$PREPARE_HASH" --output migration/prepare-result.json
jq '{outcome, topics: [.topics[] | {topic, action, readback}]}' migration/prepare-result.json
```

Inside the cluster the tool Job authenticates to the management API with the bootstrap's
read-only key, so `target_management_context` is ignored there and left empty. The ten
`topic_changes` must each show `"partitions": 6`. The apply result must end with
`"outcome": "prepared"` and every topic `"readback": "confirmed"`. Right after creation a
topic's leader may not be elected yet; the apply then stops with an error `partial` naming the
topic (`nonempty or unavailable`) or writes a single `"readback": "unconfirmed"` record. Both
are expected on a fresh target: re-run the same apply command with the same hash until the
result shows `prepared`. Topics already prepared come back as `"action": "already_matching"`
and are confirmed, not changed.

### 2. Edit the declaration: copy in the showcase scope

```
jq -s '.[0] * {topics: .[1].topics, groups: .[1].groups, workload: .[1].workload}' \
  migration/declaration.json kubemq/migration/declaration.example.json > migration/declaration.tmp \
  && mv migration/declaration.tmp migration/declaration.json
jq --argjson bytes "$((RECORDS * 1024))" '.workload.data_bytes = $bytes' migration/declaration.json > migration/declaration.tmp \
  && mv migration/declaration.tmp migration/declaration.json
jq '{source_profile, target_profile, topics, groups, target, applications: .workload.applications}' migration/declaration.json
```

Keep what the bootstrap filled in: `source_profile`, `target_profile` and every `target.*`
pin. Replace only `topics`, `groups` and `workload`. The seeded records are 1,024 bytes each,
hence `data_bytes = RECORDS × 1024`.

### 3. Create the immutable plan (in-cluster)

```
kmq migrate job tool --bootstrap-file migration/bootstrap.json --tool plan \
  --input migration/declaration.json --output migration/plan.json
jq '{run_id, hash, topics: (.source.topics | length), target_brokers: (.target_identity.brokers | length)}' migration/plan.json
```

The tool Job runs `kmq migrate plan --dry-run` inside the cluster against both clusters, reads
source and target identities, checks every target partition is empty and partition counts
match, and prints the plan; your machine saves it. `--output` is never overwritten: to re-plan,
delete `migration/plan.json` first.

If the plan is refused, the error's `details` list names **every** declaration problem at once
(for example `workload.semantics.schema_registry.inspected_scope is empty`). Fix them all in
one edit of `migration/declaration.json` and re-run step 3.

## Expected green output

- prepare preview → the tool wrapper prints `"outcome": "completed"` with `"output_file":
  "migration/prepare-plan.json"`; that file is the immutable preparation plan with
  `topic_changes` of 10 entries, each `"partitions": 6`, and a 64-hex-character `hash`.
- prepare apply → `"outcome": "prepared"`, 10 `topics` entries with `"action": "create"`
  (or `"none"` on a re-run), and a `coverage_gaps` list stating that users, permissions and
  quotas were not touched.
- plan → `migration/plan.json` with `"version": 3`, a 32-hex `run_id`, a 64-hex `hash`,
  10 source topics, 3 target brokers, and `request.workload.offset_authority:
  "kafka-consumer-groups"`.

## Expected duration

2–5 minutes (three tool Jobs of about a minute each).

## Gate

`migration/plan.json` exists and validates (`jq -e '.hash and .run_id' migration/plan.json`).
Otherwise stop and quote the `details` list. Resources are billing at `HOURLY_COST`.

## What this proves and does not prove

Proves: the declared scope exists on the source, the ten target topics exist with matching
partition counts and are empty, both cluster identities differ, and a plan now pins the kmq
version, worker image, server image, operator image and chart version for every later Job.

Does not prove: anything about the data (nothing has been copied yet), about consumer-group
offsets on the target (never seeded in this showcase), or about applications (the one declared
is a placeholder with no code).
