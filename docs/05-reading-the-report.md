# Reading the report

The migration worker writes `report-<generation>.json` onto the state volume when the
`report` Job completes. Prompt 07 copies it to `migration/report.json`. This page explains how
to get it and what each field means. Field names and meanings come from the report's Go type
in the kmq source at the pinned version. The example values below are from the unedited
report of one real run of this repository, `examples/reports/gcp-500k-report.json` (GCP,
500,000 records, 2026-10-04), walked through field by field in
`examples/reports/explained.md`.

> **Proves / does not prove**
>
> **Proves:** what the worker observed and recorded — which partitions were mapped, that the
> checkpoint database is internally consistent, which acknowledgement policy the target
> reported when the worker looked, and whether a full verification was recorded.
>
> **Does not prove:** that a production migration is complete. The report "describes its
> captured scope and evidence; it does not declare a production migration complete". It is
> offline: it did not re-check the live clusters (`live_clusters_rechecked` is `false`), it
> cannot establish that a crashed worker was fenced, and it cannot explain target writes that
> were never checkpointed.

## Getting the file

1. `kmq migrate job status --plan migration/plan.json` — when the report Job has completed,
   `progress.result_location` is `/state/report-<generation>.json`. The `generation` is the
   Job's sequence number for this run (1 = replicate, 2 = verify, 3 = report in a clean run).
2. kmq has no "copy a file out of the volume" command (`kmq migrate job logs` returns the
   worker's log text, bounded by `--limit-bytes`). The volume is `ReadWriteOnce`, so once the
   report Job's pod is gone a helper pod can mount it read-only. Prompt 07 does this with a
   `busybox` pod running as the worker's user id (65532) and `kubectl exec ... cat`.
3. Delete the helper pod before submitting any other Job.

## Field by field

Top level (`CheckpointReport`):

| Field | Meaning |
|---|---|
| `contract_version` | Report schema version (`3` at kmq v3.6.14). |
| `run_id` | The plan's 32-hex run identity (`70de6753bec42fa136fdd61b7489387c` on the reference run). Must equal `run_id` in `migration/plan.json`. |
| `plan_hash` | The plan's hash. Must equal `hash` in `migration/plan.json`. A report for another plan is not your report. |
| `report_file` | Where the worker wrote it (`/state/report-3.json` in a clean run: generation 3 after replicate and verify). |
| `generated_at` | When. |
| `source` | The source identity recorded in the plan: Kafka cluster id and, per topic, its creation identity and partition count. |
| `target` | The target identity: operator deployment id, Kafka cluster id, one broker entry per server (Kafka address and data-volume identity), and per topic its creation identity and partition count. |
| `groups` | The consumer groups the plan declared. Listing them does **not** mean their offsets exist on the target; this showcase never seeds them. |
| `applications` | The applications the plan declared (here the one placeholder). |
| `partitions` | One entry per source partition — see below. 60 in this showcase. |
| `mapping_hash` | Hash over the recorded source-to-target offset mapping. |
| `database_integrity` | `pages_checked: true` means the checkpoint database's pages were walked and consistent; `size_bytes` and `sha256` identify the exact file inspected (50,409,472 bytes for 60 partitions on the reference run). |
| `ack_policy_observation` | `recorded: true` with `policy: "strict"` means the replicate worker read the target's acknowledgement policy and stored it before copying. It is the policy **at that moment**. |
| `target_durability_baseline` | A second point observation, taken by the report Job: per server its address, data-volume id, `boot_id`, `engine_incarnation_id` and `ack_policy` (`strict` on all three servers of the reference run), with `observed_at`. |
| `verification` | See below. This is the field that matters most. |
| `cutover_journal`, `cutover_workflow`, `cutover_completion` | Empty or absent in this showcase: no cutover stage ran. |
| `live_clusters_rechecked` | Always `false` for a report: it is an offline read. |

`partitions[]` (`ReportPartition`):

| Field | Meaning |
|---|---|
| `topic`, `partition` | Which partition. |
| `source_start` | The first source offset in scope. |
| `mapped` | `true` when the checkpoint holds a source-to-target mapping for this partition. Every partition should be `true` after a completed replicate. |
| `source_watermark` | The source high watermark the worker observed when it started copying; the copy covers `source_start` up to here. |

`verification` (`ReportVerification`):

| Field | Meaning |
|---|---|
| `status` | `checkpoint_consistent` — a recorded full verification exists and is consistent with the checkpoint's partition scope and boundaries. `unavailable` — no recorded verification (the verify Job did not run with `--record`, or did not complete). Any other value with a `reason` is a defect to read. |
| `reason` | Why `status` is not `checkpoint_consistent`, when it is not. |
| `evidence` | The recorded verification: per partition, the boundary that was compared. Its scope must equal the checkpoint's partition scope, and a boundary that is "incomplete or stale" is refused with the message "copy and verify the final tail". |

The verify Job's own output (in `kmq migrate job logs`) carries the per-partition detail that
the report summarizes: `total_mapped` (should equal the seeded record count),
`payload_bytes_verified`, `elapsed_milliseconds`, `evidence_recorded: true`, and per partition
`verified_through`, `mapped_records`, `unmapped_target_records` (should be 0),
`unverified_target_prefix` and `unverified_target_tail` (should be `false`), and
`caught_up_at_observation`.

## What a good report looks like, in one paragraph

`run_id` and `plan_hash` match your plan; 60 `partitions`, all `mapped: true`;
`ack_policy_observation.recorded: true` with `policy: "strict"`; `database_integrity.pages_checked:
true`; `verification.status: "checkpoint_consistent"` with a non-empty `evidence`; the cutover
fields absent; `live_clusters_rechecked: false`. The verify log said `total_mapped` equals the
number you seeded and every partition had zero unmapped target records. The reference run
matched every item on this list: `total_mapped` 500000, `payload_bytes_verified` 547488900,
and in all 60 evidence entries `unmapped_target_records: 0`, both `unverified_*` flags
`false`, `caught_up_at_observation: true`.

## What a good report does not tell you

- Whether anything was written to the source after the replicate Job observed the high
  watermarks. (Nothing was, in this showcase; a real source keeps moving.)
- Whether consumers could resume on the target. No offsets were seeded.
- Whether the target's acknowledgement policy stayed strict between the worker's observations.
- Whether a worker that crashed mid-run was fenced. The report cannot establish that; see the
  recovery pointer in `docs/04-migration-flow.md`.

## Reference numbers, with their qualifiers

Observed on one run of this repository on GCP (2026-10-04, kmq v3.6.14, default seed of
500,000 records × 1,024 bytes, ten topics, 60 partitions): the replicate Job reported
`total_copied` 500000, `payload_bytes_copied` 547488900 and `elapsed_milliseconds` 20361
(about 24,600 records per second, about 26.9 MB per second of worker time; about 1 minute
wall clock from submit to completed); the verify Job reported `total_mapped` 500000,
`payload_bytes_verified` 547488900 and `elapsed_milliseconds` 7202. Observed once, with that
network and that target; not a guarantee. The report of that run is published unedited as
`examples/reports/gcp-500k-report.json`. An earlier internal fixture with 5,000,000 records
copied in about 1,108 seconds of worker time and verified in about 99 seconds; that was a
different rig, and is quoted only to show that per-record rates vary widely between runs.
