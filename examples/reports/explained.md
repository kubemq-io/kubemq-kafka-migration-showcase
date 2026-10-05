# `gcp-500k-report.json`, explained

A walk through the reference report, top-level field by top-level field, using the values
actually in the file. Field meanings are the ones in `docs/05-reading-the-report.md` (taken
from the report's Go type in kmq v3.6.14). For each field: what the value is, what it proves,
and what it does not.

The run: 500,000 records of 1,024 bytes, 10 topics × 6 partitions, copied from a 3-broker
Apache Kafka 4.3.1 cluster into a 3-server KubeMQ cluster on GKE on 2026-10-04. The replicate
Job was generation 1, verify generation 2, report generation 3.

## Identity of the report

```json
"contract_version": 3,
"run_id": "70de6753bec42fa136fdd61b7489387c",
"plan_hash": "afdc5c6cb67e7a6e2656b1ccddc6aeef7d8d849087eff0c21c20b911a78b7b7b",
"report_file": "/state/report-3.json",
"generated_at": "2026-10-04T14:12:08.367719477Z"
```

`run_id` and `plan_hash` are the values from `migration/plan.json` of that run; the report
Job's name, `kmq-70de6753bec42fa1-…`, carries the first half of the run id. **Proves:** this
file belongs to that plan and no other. **Does not prove:** anything about the plan's
correctness; a report for a wrong plan is still a valid report of that wrong plan. Check these
two values against your own plan file before reading anything else.

## `source`

```json
"source": {
  "cluster_id": "dtln_1K0VuCVbSYHy7B0GQ",
  "topics": { "audit": {"creation_id": "eP3mJkvCSrm/mAD7S8sxzQ==", "partition_count": 6}, "… 9 more …" }
}
```

The source Kafka cluster id and, for each of the 10 topics, its creation identity and
partition count (6 everywhere). These are what the plan bound; the worker refuses a source
whose topic identities differ. **Proves:** which Kafka cluster and which exact topic
incarnations were read. **Does not prove:** anything about the topics' configuration beyond
partition count; retention and compaction were not inspected here.

## `target`

```json
"target": {
  "deployment_id": "62285d4a-d421-448e-8d12-2dc6e7018d50",
  "kafka_cluster_id": "kubemq",
  "brokers": {
    "1": {"kafka_address": "kubemq-0.kubemq.kubemq.svc.cluster.local:9092", "data_volume_id": "7dbf9d9d-…"},
    "2": {"kafka_address": "kubemq-1.kubemq.kubemq.svc.cluster.local:9092", "data_volume_id": "ae2e9fd0-…"},
    "3": {"kafka_address": "kubemq-2.kubemq.kubemq.svc.cluster.local:9092", "data_volume_id": "a4b76252-…"}
  },
  "topics": { "audit": {"creation_id": "fa49b922-bf63-459f-bc5d-f6b827d1928b", "partition_count": 6}, "… 9 more …" }
}
```

The KubeMQ operator's deployment id, the target's Kafka-protocol cluster id, one entry per
server (in-cluster address and the identity of its data volume) and, per topic, the creation
identity the `prepare` step produced and the plan bound. **Proves:** the copy went to those
three servers and those exact empty topics (created by `prepare` minutes earlier, which is
why their ids are UUIDs while the source's are Kafka base64 ids). **Does not prove:** that
the same volumes are still attached today; it is a record of the run, not a live check.

## `groups` and `applications`

```json
"groups": ["analytics", "billing", "archiver"],
"applications": [{"name": "showcase-consumer", "revision": "git:0000000"}]
```

What the declaration listed. The seeder committed offsets for these three groups on the
source (100%, 50% and 10% of each partition). **Proves:** the plan knew about them.
**Does not prove:** that their offsets exist on the target. No offset translation ran in
this showcase; consumers could not resume on KubeMQ from this report alone. The application
is the placeholder the declaration example ships with.

## `partitions` (60 entries)

```json
{"topic": "audit", "partition": 0, "source_start": 0, "mapped": true, "source_watermark": 8309}
```

One entry per source partition. `source_start` is the first offset in scope (0 everywhere:
the topics were freshly seeded), `mapped: true` means the checkpoint holds a source-to-target
offset mapping for the partition, and `source_watermark` is the last source offset the
worker saw when it started (8,309 here, i.e. 8,310 records in this partition; the seeder's
keys hash unevenly, so partitions hold between 7,640 and 8,920 records, 50,000 per topic).
All 60 are `mapped: true`. **Proves:** every partition was copied and checkpointed.
**Does not prove:** that nothing was appended to the source after the watermark was read.
Nothing was, in this showcase; a live source would keep moving.

## `mapping_hash`

```json
"mapping_hash": "bcc8a132dff2b66b79ff08c47159223c3f9b559786b2cf799f3505cc2a47987e"
```

A hash over the recorded source-to-target offset mapping. The same value appears under
`verification.evidence.mapping_hash`, which is how the report ties the recorded verification
to this checkpoint. **Proves:** verify and report looked at the same mapping.

## `database_integrity`

```json
"database_integrity": {"pages_checked": true, "size_bytes": 50409472, "sha256": "780a7589…"}
```

The worker walked every page of the checkpoint database (about 50 MB for 60 partitions)
and found it consistent; size and hash identify the exact file. **Proves:** the checkpoint
file was not truncated or corrupted when the report was generated. **Does not prove:** that
its contents are complete; that is what `verification` is for.

## `ack_policy_observation`

```json
"ack_policy_observation": {"recorded": true, "policy": "strict"}
```

The replicate worker read the target's acknowledgement policy before copying and recorded
`strict` (every write acknowledged only after durable commit). **Proves:** the policy was
strict at that moment. **Does not prove:** that it stayed strict throughout the copy, or is
strict now. It is a point observation. `target_durability_baseline` below is a second point
observation, taken by the report Job.

## `target_durability_baseline`

```json
"target_durability_baseline": {
  "deployment_id": "62285d4a-d421-448e-8d12-2dc6e7018d50",
  "kafka_cluster_id": "kubemq",
  "observed_at": "2026-10-04T14:09:38.630736884Z",
  "nodes": { "1": {"…": "…", "boot_id": "90ca5260-…", "engine_incarnation_id": "d25ecf75-…", "ack_policy": "strict"}, "2": "…", "3": "…" }
}
```

Per server: address, data volume id, a boot id and an engine incarnation id (which change
when a server restarts or its storage engine is re-initialised), and the acknowledgement
policy, `strict` on all three. **Proves:** at 14:09:38 UTC, all three servers were the ones
the plan targeted and were running with strict acknowledgement. Comparing the boot and
incarnation ids with a later observation would reveal a restart in between. **Does not
prove:** anything about the interval between observations.

## `verification` — the field that matters

```json
"verification": {
  "status": "checkpoint_consistent",
  "evidence": {
    "plan_hash": "afdc5c6c…",
    "mapping_hash": "bcc8a132…",
    "observed_at": "2026-10-04T14:10:57.449073178Z",
    "partitions": [
      {"topic": "audit", "partition": 0, "source_start": 0, "verified_through": 8309,
       "mapped_records": 8310, "record_bytes_verified": 9056055,
       "source_end_at_observation": 8310, "target_start_at_observation": 0,
       "target_end_at_observation": 8310, "unmapped_target_records": 0,
       "unverified_target_prefix": false, "unverified_target_tail": false,
       "caught_up_at_observation": true},
      "… 59 more …"
    ]
  }
}
```

`status: "checkpoint_consistent"` means a recorded full verification exists (the verify Job
ran with `--record`) and its scope and boundaries match the checkpoint's 60 partitions. The
only other value is `"unavailable"`; anything else comes with a `reason` and is a defect to
read.

What the 60 evidence entries say, summed: `mapped_records` totals 500,000 (the seeded
count) and `record_bytes_verified` totals 547,488,900 (the 1,024-byte payloads plus keys and
headers). In every partition `verified_through` equals `mapped_records - 1`, the source and
target ends at observation are equal, `unmapped_target_records` is 0, both `unverified_*`
flags are `false` and `caught_up_at_observation` is `true`. That means: no record on the
target lacks a source counterpart, no stretch of the target before or after the mapped
range escaped comparison, and the source had not moved past the copied boundary when
verify looked.

**Proves:** every copied record was compared with its source over the recorded boundaries,
and the recorded result is consistent with the checkpoint. **Does not prove:** anything
about records written to the source after `observed_at`; that the target's data is still
intact today; or that an application could switch over. A passing verify certifies copied
history only.

## What is absent

There are no `cutover_journal`, `cutover_workflow` or `cutover_completion` fields: no
cutover stage ran. `live_clusters_rechecked` is `false`: the report Job reads the checkpoint
only and never dialled either cluster (`--target-api` is refused for `report`). The report
also cannot tell you whether a worker that crashed mid-run was fenced; this run had no
interruption, so the question did not arise.

## The numbers behind it, with qualifiers

From the Job logs of the same run, not from this file: replicate copied 500,000 records in
20,361 milliseconds of worker time (about 24,600 records per second, about 26.9 MB per
second); verify took 7,202 milliseconds. Observed once, on one GCP rig, with the seeder's
fixture. Not a capacity guarantee.
