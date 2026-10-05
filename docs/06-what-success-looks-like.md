# What success looks like

Green output per step, with expected durations. The field names, state strings and shapes
are taken from the kmq source at the pinned version. Where a value is quoted as **observed**
it is the value from one real run of this repository (GCP, default 500,000-record seed,
kmq v3.6.14, 2026-10-04; its report is published unedited under `examples/reports/`).
Values that depend on your environment are shown as `<...>`, and a snippet is marked
**illustrative** only where no real value was recorded.

Durations are for the default 500,000-record seed on the tested machine types; the
"observed" column at the end of this page is one run, not a guarantee. Your numbers will
differ.

## 01 — Infrastructure (15–35 min; observed about 25 min on GCP)

```
kafka ready: quorum answered and 3 brokers registered (attempt <n>)
Apply complete! Resources: 34 added, 0 changed, 0 destroyed.
Apply complete! Resources: 4 added, 0 changed, 0 destroyed.
✅ wrote .rig/env:
   ✅ KRaft leader elected (node <id>)
   ✅ 3/3 brokers answering on the INTERNAL listener
   ✅ kcat sees 3 brokers
KAFKA RIG OK
```

Resource counts are the observed GCP ones (34 in `infra`, 4 in `k8s-addons`); AWS differs.
On the reference run the `infra` apply took about 25 minutes from plan to outputs, with GKE
cluster creation and the Kafka quorum gate dominating; the `k8s-addons` apply took under a
minute.

Green means: both Terraform roots applied, `.rig/env` has every key, `make status` ends with
`KAFKA RIG OK` and exits 0 (the seed-data section says "not seeded yet" until prompt 02).

## 02 — Seed (3–8 min including compile and copy)

```
== producing 50000 records per topic x 10 topics = 500000 records of 1024 bytes (<k> keys/topic) ==
   500000 acked  (<rate> rec/s, <mb> MB/s)  errors=0
   produced 500000/500000 in <t> (<rate> rec/s, <mb> MB/s), errors=0
   (verifier: 10 topics, 60 partitions, 500000 records, 3 groups with committed offsets)
✅ seeded; wrote .rig/seed.env
```

Observed: the 500,000-record produce finished in 1 second (about 505,000 records per
second); the 5,000,000-record seed produced in 9 seconds (about 566,000 records per second,
about 579 MB per second). The verifier passed both times: 3 brokers, 10 topics × 6
partitions with replication factor 3, groups `analytics`/`billing`/`archiver` at
100/50/10 %. The seeder runs on the driver VM next to the brokers; these are fixture rates,
not a Kafka benchmark.

Green means: `errors=0` and the verifier's total equals `RECORDS`.

## 03 — Install kmq and KubeMQ (10–20 min; observed about 10 min)

`kmq version` (real shape):

```json
{"version": "v3.6.14", "commit": "<short sha>"}
```

`kmq deploy prepare` (real shape, values illustrative):

```json
{"state": "prerequisites_prepared", "recipe": ".rig/recipe.json", "next_action": "deploy_plan_with_prepared_recipe"}
```

`kmq deploy apply` (real field names; the `next_action` string is what kmq prints for a
Kubernetes target):

```json
{
  "installation_id": "<32 hex>",
  "state": "<kmq state after install>",
  "target": "kubernetes",
  "resource_id": "<KubemqCluster UID>",
  "data_retained": true,
  "next_action": "run_deploy_status_until_cluster_ready_then_deploy_forward_all_then_auth_login_all_bootstrap_then_verify"
}
```

`kmq deploy status` once the cluster is up (observed state string; about 10 minutes after
`kmq deploy prepare` on the reference run, once all three pods were Ready):

```json
{"installation_id": "<32 hex>", "state": "cluster_ready_needs_authenticated_verification", "target": "kubernetes", "data_retained": true, "next_action": "deploy_forward_all_then_auth_login_all_bootstrap_then_deploy_verify"}
```

While forming, `state` is `cluster_not_ready` with `next_action:
run_deploy_status_again_until_cluster_ready_or_deploy_diagnose`. After `kmq deploy verify`,
`state` becomes `cluster_ready_verified` on later status calls.

`kmq deploy forward --all` prints one object per server as each tunnel opens (real field
names):

```json
{"kubernetes_context": "<ctx>", "namespace": "kubemq", "pod": "kubemq-0", "pod_uid": "<uid>", "server_index": 0, "endpoint": "https://127.0.0.1:18080", "local_port": 18080, "remote_port": 8080}
```

`kmq auth login --all` ends with `"state": "authenticated"` and a `servers` list of three.
Observed: the first login must be
`kmq auth login --all --bootstrap --username admin --new-password-stdin --non-interactive`,
because the seeded one-time password has to be replaced; a plain `--password-stdin` login
returns `password_change_required` (see [docs/07](07-troubleshooting.md)).
`kmq deploy verify` ends with `"state": "verified"` (observed).

## 04 — Bootstrap, probe, target-check (5–10 min)

`kmq migrate assess --check` (table output; real headings; the counts below are the observed
ones: migratable, 10 topics, none blocked):

```
Source cluster: <cluster id>  (3 broker(s), <version>)
Migratable: YES
Topics: 10 READY  0 CAVEAT  0 UNKNOWN  0 BLOCKED   Groups: 3 (0 active)

[READY] audit  (6 partitions)
[READY] clicks  (6 partitions)
...
Consumer groups (all require exact offset translation at cutover):
  - analytics  [<group state> (inactive)]
  - archiver  [<group state> (inactive)]
  - billing  [<group state> (inactive)]

VERIFY MANUALLY (a config scan cannot determine these — config != data):
  - ...
```

`kmq migrate job bootstrap` (real top-level keys; `"outcome": "ready"` observed, the other
values depend on your environment):

```json
{
  "contract_version": 1,
  "operation": "migrate.job.bootstrap",
  "outcome": "ready",
  "bootstrap_file": "migration/bootstrap.json",
  "declaration_file": "migration/declaration.json",
  "declaration_written": true,
  "bootstrap": {
    "installation_id": "<32 hex>",
    "cluster_name": "kubemq",
    "worker_image": "<repository>@sha256:<digest>",
    "worker_image_pinned": true,
    "state_pvc": "kubemq-migration-state",
    "profiles_configmap": "kubemq-migration-profiles",
    "credential_secret": "kubemq-migration-credentials",
    "service_account": "kubemq-migration-worker",
    "state_user_id": 65532,
    "source_profile": "kafka-src-worker",
    "target_profile": "kubemq-target",
    "target_api": [
      "https://kubemq-0.kubemq.kubemq.svc.cluster.local:8080",
      "https://kubemq-1.kubemq.kubemq.svc.cluster.local:8080",
      "https://kubemq-2.kubemq.kubemq.svc.cluster.local:8080"
    ]
  },
  "next_steps": ["Edit migration/declaration.json: ...", "kmq migrate job tool --tool plan ...", "kmq migrate job submit ... --operation replicate"],
  "notes": ["Credential Secret \"kubemq-migration-credentials\" is verified on rerun by its key names only; ...", "Every object is bound to a run by its UID once the first Job is submitted; ..."]
}
```

`kmq migrate job tool --tool probe` wrapper (real keys) and result (real keys; observed:
`"outcome": "reachable"`, 3 source brokers, `topic_count` 10, 3 target brokers, and
`"store_ack_policy": "strict"` on all three target APIs; addresses and ids are yours):

```json
{"contract_version": 1, "operation": "migrate.job.tool", "tool": "probe", "job": "kmq-tool-probe-<hex>", "job_uid": "<uid>", "outcome": "completed", "output_file": "migration/probe.json"}
```

```json
{
  "outcome": "reachable",
  "source": {"bootstrap": ["<int1>:9092", "<int2>:9092", "<int3>:9092"], "reachable": true, "cluster_id": "<id>", "brokers": [{"id": 1, "address": "<int1>:9092"}, {"id": 2, "address": "..."}, {"id": 3, "address": "..."}], "topic_count": 10},
  "target": {"bootstrap": ["kubemq-0.kubemq.kubemq.svc.cluster.local:9092", "..."], "reachable": true, "brokers": [{"id": 0, "address": "..."}, {"id": 1, "address": "..."}, {"id": 2, "address": "..."}], "topic_count": 0},
  "target_apis": [
    {"url": "https://kubemq-0.kubemq.kubemq.svc.cluster.local:8080", "reachable": true, "ready": true, "role": "<leader|follower>", "store_ack_policy": "strict", "auth_enabled": true, "identity_answered": true},
    {"url": "https://kubemq-1....:8080", "reachable": true, "ready": true, "store_ack_policy": "strict", "auth_enabled": true, "identity_answered": true},
    {"url": "https://kubemq-2....:8080", "reachable": true, "ready": true, "store_ack_policy": "strict", "auth_enabled": true, "identity_answered": true}
  ]
}
```

`--tool target-check` result (real keys; observed: `"outcome": "ready_at_observation"` with
`"ack_policy": "strict"` on all three nodes):

```json
{
  "contract_version": 1,
  "operation": "migrate.target-check",
  "outcome": "ready_at_observation",
  "deployment_id": "<operator deployment id>",
  "kafka_cluster_id": "<target kafka cluster id>",
  "nodes": [
    {"broker_id": 0, "kafka_address": "kubemq-0....:9092", "management_api": "https://kubemq-0....:8080", "node_data_volume_id": "<id>", "ack_policy": "strict"},
    {"broker_id": 1, "...": "..."},
    {"broker_id": 2, "...": "..."}
  ],
  "coverage_gaps": ["<what was not checked, always non-empty>"]
}
```

Red here looks like `"outcome": "not_ready"` with an `error` field, or `"outcome":
"unreachable"` from the probe.

## 05 — Prepare and plan (2–5 min)

Prepare preview file (`migration/prepare-plan.json`, real keys):

```json
{"version": 1, "created_at": "<time>", "request": {"...": "..."}, "topic_changes": [{"name": "audit", "partitions": 6, "retention_ms": "<ms>"}, "... 10 entries ..."], "hash": "<64 hex>"}
```

Prepare apply result (real keys; `"outcome": "prepared"` observed):

```json
{"contract_version": 1, "operation": "migrate.prepare", "outcome": "prepared", "plan_hash": "<64 hex>", "target_deployment_id": "<id>", "topics": ["... one per topic with action create ..."], "coverage_gaps": ["Security policies, users and quotas were not modified or verified by kmq.", "Create the final migration plan now to bind target topic creation identities."]}
```

Observed on a fresh target: the first apply stopped with error code `partial` ("target
topic audit partition 0 is nonempty or unavailable"), a second apply recorded one topic as
`readback: unconfirmed`, and the third apply with the same `--approve-hash` returned
`"outcome": "prepared"` with all 10 topics `already_matching` / `confirmed`. That is the
freshly created topics' partition leaders still being elected; re-run with the same hash
until the outcome is `prepared` (see [docs/07](07-troubleshooting.md)).

Plan (`migration/plan.json`, real top-level keys; observed run id
`70de6753bec42fa136fdd61b7489387c`, 10 topics, 3 target brokers):

```json
{"version": 3, "run_id": "70de6753bec42fa136fdd61b7489387c", "created_at": "<time>", "request": {"...": "the declaration with hashes and worker_kmq_version filled"}, "source": {"cluster_id": "<id>", "topics": {"audit": {"creation_id": "<id>", "partition_count": 6}, "...": "..."}}, "target_identity": {"deployment_id": "<id>", "kafka_cluster_id": "<id>", "brokers": {"0": {"...": "..."}, "1": {"...": "..."}, "2": {"...": "..."}}, "topics": {"...": "..."}}, "hash": "<64 hex>"}
```

A refused plan looks like an error whose `details` list names every problem. Observed:
`migration plan requires at least one source writer`, fixed by naming the seeder as the
source writer (`showcase-seeder`) in the declaration. Another example of the same shape:
`workload.semantics.schema_registry.inspected_scope is empty; list the planned applications,
topics and groups the Schema Registry dependency statement actually covers`.

## 06 — Replicate (5–15 min at default seed; observed about 1 min wall clock)

`kmq migrate job submit` (real keys):

```json
{"run_id": "<32 hex>", "job": "kmq-<first 16 hex of run id>-1-replicate", "operation": "replicate", "job_uid": "<uid>", "state": "<submitted state>", "generation": 1, "observed_at": "<time>"}
```

`kmq migrate job status` while running (real keys):

```json
{"run_id": "<32 hex>", "job": "kmq-<first 16 hex of run id>-1-replicate", "operation": "replicate", "generation": "1", "observed_at": "<time>", "state": "running", "progress": {"freshness": "fresh", "phase": "running", "committed_records_this_job": 123456, "heartbeat_at": "<time>", "pod_uid": "<uid>", "node_name": "<node>"}, "next_action": "the worker is running; check again with kmq migrate job status"}
```

At the end: `"state": "completed"`, `progress.phase: "completed"`, `next_action: "the Job
finished; read its result with kmq migrate job logs --plan <plan file>"`.

The worker's final summary in `kmq migrate job logs` (observed values; the Job was named
`kmq-70de6753bec42fa1-1-replicate`):

```json
{"partitions": ["... 60 entries ..."], "total_copied": 500000, "payload_bytes_copied": 547488900, "elapsed_milliseconds": 20361}
```

That is about 24,600 records per second and about 26.9 MB per second of worker time, and
about 1 minute wall clock from `submit` to `completed` including Job start-up. `payload_bytes`
exceeds 500,000 × 1,024 because keys and headers are counted. One run; not a guarantee.

Red: `"state": "failed_blocked"` with a `next_action` that starts "the worker exited with kmq
exit code N (...)".

## 07 — Verify and report (3–10 min)

Verify summary in the log (observed values; the first partition entry is the real one from
the reference report):

```json
{"observed_at": "<time>", "partitions": [{"topic": "audit", "partition": 0, "source_start": 0, "verified_through": 8309, "mapped_records": 8310, "source_end_at_observation": 8310, "target_start_at_observation": 0, "target_end_at_observation": 8310, "unmapped_target_records": 0, "unverified_target_prefix": false, "unverified_target_tail": false, "caught_up_at_observation": true}, "... 60 entries ..."], "total_mapped": 500000, "payload_bytes_verified": 547488900, "elapsed_milliseconds": 7202, "evidence_recorded": true}
```

Observed: no partition of the 60 had an unverified prefix or tail, and every one had
`unmapped_target_records: 0`.

Report Job status at the end:

```json
{"operation": "report", "state": "completed", "generation": "3", "progress": {"phase": "completed", "result_location": "/state/report-3.json", "...": "..."}}
```

`migration/report.json` (observed values, abridged from
`examples/reports/gcp-500k-report.json`; see `docs/05-reading-the-report.md`):

```json
{"contract_version": 3, "run_id": "70de6753bec42fa136fdd61b7489387c", "plan_hash": "afdc5c6c…", "report_file": "/state/report-3.json", "generated_at": "2026-10-04T14:12:08Z", "source": {"...": "..."}, "target": {"...": "..."}, "groups": ["analytics", "billing", "archiver"], "applications": [{"name": "showcase-consumer", "revision": "git:0000000"}], "partitions": [{"topic": "audit", "partition": 0, "source_start": 0, "mapped": true, "source_watermark": 8309}, "... 60 entries ..."], "mapping_hash": "bcc8a132…", "database_integrity": {"pages_checked": true, "size_bytes": 50409472, "sha256": "780a7589…"}, "ack_policy_observation": {"recorded": true, "policy": "strict"}, "target_durability_baseline": {"...": "per-node ack_policy strict"}, "verification": {"status": "checkpoint_consistent", "evidence": {"...": "60 partitions"}}, "live_clusters_rechecked": false}
```

Retrieval observed as prompt 07 describes: a `busybox` helper pod mounting the state volume
read-only, `kubectl exec ... cat /state/report-3.json`, helper pod deleted afterwards.

## 08 — Teardown (10–20 min)

```
Destroy complete! Resources: <n> destroyed.
Destroy complete! Resources: <n> destroyed.
TEARDOWN VERIFIED CLEAN
```

Only that last line, exactly, means nothing is billing.

## Expected durations, summarized

| Step | Default seed | Notes |
|---|---|---|
| 01 infra | 15–35 min | EKS slower than GKE |
| 02 seed | 3–8 min | first run compiles the seeder |
| 03 install | 10–20 min | image pull and volume bind dominate |
| 04 bootstrap + probe | 5–10 min | worker image pulled once |
| 05 prepare + plan | 2–5 min | three one-off Jobs |
| 06 replicate | 5–15 min | observed about 1 min wall clock for 500,000 records (20.4 s of worker time); not a guarantee |
| 07 verify + report | 3–10 min | observed 7.2 s of verify worker time for 500,000 records; retrieval adds the busybox pull; not a guarantee |
| 08 teardown | 10–20 min | cluster deletion dominates |

## Observed on the first run

One run of this repository on GCP, 2026-10-04 UTC, default 500,000-record seed, kmq v3.6.14,
Kafka 4.3.1, chart 3.4.0, a single US zone. One observation each; none is a guarantee.

| Step | Observed | Detail |
|---|---|---|
| `terraform apply` of `gcp/infra` | about 25 min | 34 resources; plan at 13:07, outputs written at 13:32; GKE creation and the Kafka quorum gate dominate |
| `terraform apply` of `gcp/k8s-addons` | under 1 min | 4 resources |
| Seed, 500,000 records | 1 s of produce time | about 505,000 records per second; verifier passed |
| Seed, 5,000,000 records | 9 s of produce time | about 566,000 records per second, about 579 MB per second; verifier passed |
| `kmq deploy prepare` → three pods Ready → `status` = `cluster_ready_needs_authenticated_verification` | about 10 min | end to end |
| Replicate, 500,000 records | about 1 min wall clock | `elapsed_milliseconds` 20361; about 24,600 records per second, about 26.9 MB per second |
| Verify, 500,000 records | `elapsed_milliseconds` 7202 | 60 partitions, none with an unverified prefix or tail |
| Report (generation 3) | under a minute plus retrieval | `checkpoint_consistent`, 60 partitions, strict acknowledgement recorded |
| First apply to report in hand | about 65 min | including the debugging described under 03 and 05; a clean rerun following the prompts should be about 50 min |
| Cost | about USD 3 for the run | about USD 2.50 per hour while up (Kafka about 1.80, GKE about 0.70) |
