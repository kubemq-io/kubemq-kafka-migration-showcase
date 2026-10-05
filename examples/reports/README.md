# Reference report

`gcp-500k-report.json` is **the report from one real run of this repository**, published
exactly as the migration worker wrote it to the state volume (`/state/report-3.json`) and as
prompt 07 copies it out with the busybox helper pod. It has not been edited, trimmed or
redacted. `explained.md` walks through its fields using the values in the file.

| | |
|---|---|
| Date | 2026-10-04 (UTC) |
| Cloud | Google Cloud, one zone, GKE regular channel |
| Source | Apache Kafka 4.3.1 (KRaft), 3 brokers, 10 topics × 6 partitions, replication factor 3 |
| Seed | 500,000 records × 1,024 bytes (the default seed), 3 consumer groups |
| `kmq` | v3.6.14 |
| KubeMQ | server image `kubemq-next` v3.6.14, chart 3.4.0 (pinned by `kmq deploy prepare`), 3 servers |
| Report generation | 3 (Job 1 replicate, Job 2 verify, Job 3 report) |

## Identifiers in the file

The report carries a `run_id`, a `plan_hash`, the source Kafka `cluster_id`, the target
operator `deployment_id`, per-server `data_volume_id`, `boot_id` and `engine_incarnation_id`
values, per-topic `creation_id` values, a checkpoint-database `sha256`, timestamps, and the
in-cluster pod names `kubemq-0..2.kubemq.kubemq.svc.cluster.local`. They are kept because the
report is meaningless without them. **They identify a throwaway rig that was destroyed the
same day.** None is a secret, and the file contains no IP addresses, cloud project ids,
hostnames outside the cluster DNS, or operator identity (checked with `grep` before publishing).

## What it does and does not show

It shows that `kmq migrate` copied all 500,000 seeded records into KubeMQ, that a recorded
full verification is consistent with the checkpoint over every one of the 60 partition
boundaries (`verification.status: "checkpoint_consistent"`), and that the target reported a
strict acknowledgement policy when the worker looked. It does not certify records written to
the source after the copy, it is not an application cutover (no cutover fields are present),
and it is an offline read (`live_clusters_rechecked: false`). The `kmq migrate` command
surface is development-grade and has not been qualified for production migrations.

## Your numbers will differ

On this run the replicate Job copied 500,000 records (547,488,900 payload bytes) in 20,361
milliseconds of worker time, about 24,600 records per second, and the verify Job compared
them in 7,202 milliseconds. Those figures were observed once, on one rig, with the seeder's
fixture; they are not a capacity guarantee for your topics, record sizes, network or target.
Compare the **shape** of your report with this one, not the numbers.

Field meanings come from `docs/05-reading-the-report.md`; a green run end to end is described
in `docs/06-what-success-looks-like.md`.
