# The migration flow, step by step

This page explains what each `kmq migrate` step does, what it proves, and what it does not
prove. It is written for the person reading the agent's transcript, not for the agent; the
exact commands are in `prompts/03` through `prompts/07`.

Every statement about kmq behavior on this page was checked against the kmq source at the
version this repository pins (`versions.env`). Where we quote a number, we say where it was
observed and that it is not a guarantee.

> **Proves / does not prove**
>
> **Proves:** a real 3-broker Apache Kafka cluster's selected topics can be bulk-copied into a
> 3-server KubeMQ cluster by a worker running inside Kubernetes, that every copied record can
> be re-read from both sides and compared, and that the evidence of that comparison can be
> exported as a report.
>
> **Does not prove:** anything after the copy. No consumer-group offsets are seeded on the
> target, no application is switched over, no source writer is paused, no recovery after a
> worker crash is exercised. The observed rates are from one fixture, not a capacity
> statement. The command surface is development-grade, not a production-qualified release.
> Amazon MSK and Confluent Cloud are not qualified sources.

## The shape of the flow

```
laptop                                   Kubernetes cluster (target)
------                                   --------------------------
kmq deploy prepare / plan / apply  --->  operator + 3 KubeMQ servers
kmq auth login (over loopback tunnels)
kmq kafka profile create kafka-src
kmq migrate assess  (reads Kafka only)
kmq migrate job bootstrap          --->  PVC, ConfigMap, Secret, ServiceAccounts
kmq migrate job tool --tool probe  --->  one-off Job: dial source, target, management APIs
kmq migrate job tool --tool target-check
kmq migrate job tool --tool prepare (preview, then apply)  --->  create 10 empty target topics
edit declaration.json
kmq migrate job tool --tool plan   --->  one-off Job prints the immutable plan
kmq migrate job submit replicate   --->  worker Job, state volume, 3 target APIs
kmq migrate job submit verify      --->  worker Job, same volume
kmq migrate job submit report      --->  worker Job, volume only, no target API
helper pod copies report.json out of the volume
```

Everything that **binds identity or moves data** runs inside the cluster as a Kubernetes Job.
The laptop authors files, submits Jobs and reads status. This is not a convenience; the plan
and every data operation need one direct management address per target server whose host
name equals the host the Kafka listener advertises, and those are the per-pod in-cluster names
(`kubemq-N.kubemq.<namespace>.svc.cluster.local`). A laptop cannot satisfy that; a Job can.

## Step by step

### Install KubeMQ with `kmq deploy`

`kmq deploy prepare --input` validates a recipe (3 servers, your storage class, 50Gi volumes,
your license and TLS Secrets), downloads the chart pinned in this kmq release, resolves the
server and operator images to digests and records three loopback management endpoints.
`kmq deploy plan` saves an immutable plan with an `installation_id`. `kmq deploy apply --plan`
installs the operator release and the cluster release with values kmq fixes itself: next
storage engine, **strict disk acknowledgement** (`STORE_NEXT_ACK_POLICY=strict`),
authenticated management API over TLS, health probes on.

*Proves:* the cluster is installed the way the migration later requires, and an installation
record exists that the bootstrap reads.
*Does not prove:* that the servers are reachable from the worker network or that they report
strict acknowledgement at run time.

Why this matters: `kmq migrate job bootstrap` only works from an installation record written
by `kmq deploy`. A Helm install done by hand has no record and cannot be bootstrapped.

### Log in

`kmq deploy forward --installation <id> --all` opens one loopback tunnel per server.
`kmq auth login --installation <id> --all --bootstrap --username admin --new-password-stdin`
logs in to each server using the one-time password the operator seeded in Secret
`kubemq-api-admin`, replaces it with the password you supply on standard input, and saves one
context per server. The seeded password cannot issue service credentials until it is changed.
The migration bootstrap later uses your password once, to mint a **read-only** management key
for the worker.

### Assess the source (read-only)

`kmq migrate assess --bootstrap <external addresses> --check` scans topics and consumer groups
and grades each topic `READY`, `CAVEAT`, `UNKNOWN` or `BLOCKED`. Compacted topics and topics
with more than 256 partitions are blockers. It never produces, commits or creates anything.

*Proves:* the source's configuration has no known blocker.
*Does not prove:* anything about the data ("config != data", as the tool itself prints), or
about the applications that use it.

### Bootstrap the worker resources

`kmq migrate job bootstrap --installation <id> --source-profile kafka-src --out ./migration`
reads the KubemqCluster and refuses it unless it has at least 3 replicas, the next storage
engine, the Kafka listener not disabled, and a plaintext listener. It then creates, or on a
re-run verifies without changing:

- a Secret with a freshly minted read-only management service key (the key never leaves the
  cluster; the Secret is checked by key names only on re-run);
- an immutable ConfigMap with two Kafka profiles — a worker copy of your source profile and a
  derived target profile naming the three pod addresses on port 9092;
- a worker ServiceAccount and one per cutover stage;
- a `ReadWriteOnce` state volume (20Gi by default) that will hold the checkpoint;
- a preflight Job that runs `kmq version` in the worker image and records the exact build.

It writes `bootstrap.json` (every object with its UID, the worker image by digest, the three
management URLs, the user id 65532) and a pre-filled `declaration.json`.

*Proves:* the resources exist with recorded identities; the worker image is this kmq's build.
*Does not prove:* connectivity. That is the next step.

### Probe and target-check (in-cluster)

`kmq migrate job tool --tool probe` dials the source, the target Kafka listener and the three
management APIs from a one-off Job. `--tool target-check` connects to every advertised target
broker and reads each member's **running** acknowledgement policy, a shared deployment
identity and distinct data-volume identities.

*Proves:* the worker network reaches everything; every server reports `strict` right now.
*Does not prove:* that the policy stays strict later. "A saved configuration value is not
proof that the server is running with that value" — which is why the probe reads it live,
and why replicate reads it again and records what it saw.

### Prepare target topics (in-cluster)

The plan binds each target topic's creation identity, so the topics must exist first.
`--tool prepare` previews an immutable preparation plan (topic, partition count copied from
the source, `retention.ms` copied from the source) with a hash, then applies it only when
given that exact hash. It creates ordinary non-compacted topics and sets retention; it never
touches users, permissions or quotas and says so in its `coverage_gaps`.

*Proves:* ten empty topics with matching partition counts exist on the target.
*Does not prove:* anything about security configuration on the target.

### Declare and plan (in-cluster)

You edit `declaration.json`: the ten topics, the three groups, one placeholder application,
no source writers, the three semantic findings (`schema_registry`, `streams_state`,
`transactions`) each declared `none` with a sentence of evidence and the scope it covers, a
data-size estimate, a write rate of 0, a positive write-pause budget, and a recovery policy.
Then `--tool plan` runs `kmq migrate plan --dry-run` inside the cluster: it reads both
cluster identities, checks every target partition is empty and partition counts match,
refuses a self-migration, and prints a plan with a run id and a hash. Your laptop saves it.
The plan contains credential **references**, never credential values, and is never
overwritten.

*Proves:* the scope is well-formed and both sides match it.
*Does not prove:* that the applications you declared behave as declared. The semantic
findings are your statements; the tool requires them but cannot check them.

### Replicate

`kmq migrate job submit --operation replicate --plan ... --bootstrap-file ...` creates one
worker Job. Before copying, the worker refuses to start unless every target server reports
`Store.NextAckPolicy=strict`, and records that observation. It copies every selected record
from each partition's start offset to the high watermark observed at run start, in bounded
batches, with up to 32 partition workers in parallel, and records the acknowledged
source-to-target offset mapping in the checkpoint on the state volume.

`kmq migrate job status --plan` reads the run's ConfigMaps and the Job. Its progress block is
a heartbeat the worker publishes ("fresh" means under 15 seconds old). It is "a bounded
observation, not an authoritative cutover report".

*Proves:* every selected record was produced to the target and acknowledged under strict
disk acknowledgement; the mapping is recorded.
*Does not prove:* correctness of content. A crash between target acknowledgement and
checkpoint commit "can replay a record" — up to 32 per active partition — and "distinct
source records with identical contents must never be suppressed by comparing payloads". That
is exactly why the next step exists.

### Verify

`--operation verify` re-reads every mapped record from both sides over the recorded
boundaries and compares them. Inside the Job it runs with `--record`, so a successful full
comparison is written into the checkpoint as evidence.

*Proves:* the copied history matches the source, record by record, over the recorded
boundaries.
*Does not prove:* "later source writes or an application cutover". This is the sentence to
remember: **verify certifies copied history only**.

### Report

`--operation report` is an offline read of the checkpoint; it refuses `--target-api`. It
checks the checkpoint database pages, the offset map and the plan identity, records the
file's size and hash, and writes `report-<generation>.json` onto the state volume. kmq has no
command to copy that file out; a short-lived helper pod mounting the volume read-only does it
(prompt 07). `docs/05-reading-the-report.md` explains every field.

## Reference numbers, with their qualifiers

From the first run of this repository on GCP (kmq v3.6.14, 500,000 records of 1,024 bytes
across ten topics and 60 partitions): the replicate Job copied all 500,000 records
(547 MB) in about 20 seconds of worker time, about 24,600 records per second; full
verification of the same 500,000 records took about 7 seconds; the report Job finished in
under a minute. The whole prompt sequence took about 50 to 65 minutes wall clock, most of it
infrastructure creation. The full report is published unedited in `examples/reports/`.
Earlier internal runs with 5,000,000 records on a different fixture copied at roughly
4,500 records per second with 32 concurrent partition workers. All of these were
**observed on those fixtures**; they are not a capacity guarantee for other topics,
networks or targets. Rates vary with record size, partition count, worker concurrency and
the network between the worker and both clusters.

## Recovery after a worker interruption (referenced, not exercised)

If a worker Job fails or is interrupted, the run is blocked. `kmq migrate job recovery-check
--plan <plan> --state-pvc <claim>` reports the saved Job and volume identities, observed Pods
and candidate nodes; before a manual release it reports `fencing_proven=false` and
`replacement_allowed=false`. "A stale heartbeat, deleted Pod or failed Job is insufficient
evidence." An operator must prove, by infrastructure-level fencing, that the old worker cannot
write, then record that attestation; only then is one replacement permitted. This showcase
documents the command and does not run it. Do not "fix" a blocked run by deleting the
ownership ConfigMap or the volume.

## What this showcase deliberately leaves out

- Seeding consumer-group offsets on the target (`translate`, `cutover`): the plan records
  the groups; nothing is written to them.
- Writer pause, application stop/start, cutover approval and preflight: the commands exist
  behind an approval record; none is invoked here.
- Compacted topics, Kafka Streams state, Schema Registry: declared `none` because the seeded
  fixture has none. A real workload needs its own evidence.
- Authenticated Kafka sources, Amazon MSK, Confluent Cloud: the source profile here is
  plaintext; those need tests in those services.
