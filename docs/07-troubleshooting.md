# 07 — Troubleshooting

Traps we hit while building this, in the order you are likely to meet them. Each entry says
what you see, why it happens, and what to do.

## Preflight and tooling

### `bash: syntax error` or `declare -A: invalid option` on macOS

macOS ships bash 3.2. The scripts need bash ≥ 4 and refuse to run under 3.2.
`brew install bash`, then make sure `/opt/homebrew/bin` (Apple silicon) or `/usr/local/bin`
precedes `/bin` in your `PATH`, or run the scripts with `/opt/homebrew/bin/bash`.

### Firewall rule rejects my address, or `operator_cidr` contains a colon

Your laptop is on a dual-stack connection and the IP-detection service answered with your
IPv6 address. Cloud firewall source ranges here are IPv4. `scripts/operator-cidr.sh` uses
`curl -4` for this reason; if you wrote the tfvars by hand, use `curl -4 ifconfig.me` and
write `<address>/32`.

### `kmq reports <x> after install, pin is <y>` from `scripts/kmq-install.sh`

The installed `kmq version` does not match `KMQ_VERSION` in `versions.env`. Another `kmq`
earlier in your `PATH`, or a cached older install. Remove it or rerun the installer with the
pinned `--version`. Do not edit `versions.env` to match the binary: the worker image, the
deploy pins and the declaration example are all tied to the pinned version.

## Terraform apply

### Quota exceeded mid-apply (`QUOTA_EXCEEDED`, `VcpuLimitExceeded`, `AddressLimitExceeded`)

Some resources were created, the rest failed. You are billing for a half-built rig. Request
the increase ([docs/00](00-prerequisites.md#quotas)), then either `terraform apply` again once
it is granted (Terraform resumes) or `make CLOUD=<cloud> down` to stop the meter. Preflight
exists to catch this before apply; if preflight passed and you still hit this, the quota was
consumed by something else in the project.

### Kafka tarball download fails with HTTP 404

Apache removes old releases from the fast download CDN when a new one ships. Cloud-init tries
the CDN first and falls back to the Apache archive (complete but throttled, so the first boot
can take 10+ minutes longer). If both fail, the version in `versions.env` is gone or the
SHA-512 no longer matches: bump `KAFKA_VERSION` and `KAFKA_SHA512` to the current release
(the checksum is published next to each tarball on the Apache download page) and re-apply.
Note that this replaces the brokers and loses the seed.

### Spot or preemptible brokers vanish

`use_spot = true` is opt-in and off by default for a reason: on our first internal try two of
three brokers were reclaimed four minutes after creation, before Kafka was installed. A rig
that must hold data for an hour cannot sit on capacity the cloud may take back. Leave it off
unless you accept re-seeding at any moment.

### Readiness gate times out waiting for the quorum

SSH to the driver (`DRIVER_SSH` in `.rig/env`) and run
`sudo journalctl -u kafka-showcase-setup -b` on a broker (hop from the driver with the
broker's private IP). Common causes: tarball download still running (archive fallback), the
NVMe device not matched (see next entry), or the instance never got outbound internet.

### Broker logs `no block device MODEL matches /<regex>/ — refusing to guess`

The local disk's model string did not match `NVME_MODEL_REGEX`. The script refuses to guess
rather than format the wrong disk. On GCE local SSD reports as `nvme_card`; on AWS instance
store as `Amazon EC2 NVMe Instance Storage`. A different machine type may report differently:
check with `lsblk -dpno NAME,MODEL` and set `nvme_model_regex` in `terraform/modules/kafka-gcp`
(on AWS it is a local in `terraform/modules/kafka-aws/main.tf`).

## Kafka data

### A broker was stopped, replaced or re-applied — and the topics are empty

Local SSD (GCP) and instance store (AWS) are **ephemeral**. Any stop, preemption, or
Terraform replacement returns the broker with an empty data directory. Cloud-init re-formats
it into the existing cluster id (it refuses a different id), so the broker rejoins — with no
data. Partitions it led are now under-replicated or offline. Re-seed:

```bash
bash scripts/seed.sh --records <n> --recreate     # or: make CLOUD=<cloud> seed after wiping the topics
```

The Terraform modules carry `ignore_changes` on the fields that would otherwise force a
replacement on re-apply, but any deliberate change to machine type, image or disk replaces
the VMs. Treat the Kafka data as disposable.

## Kubernetes and networking

### `probe` Job cannot reach Kafka on 9092, but `kcat` from the laptop works on 9094

GKE pods talk to VMs in the same VPC with their **pod** address, not the node's address; the
traffic is not translated. The VPC-subnet firewall rule does not cover the pod range. This
repository creates a separate rule that admits the subnet's `pods` secondary range on 9092
and 9094; if you changed the pod range or imported an existing cluster, the rule points at
the wrong CIDR. Check `kubernetes_pod_cidr` in `terraform output` against
`kubectl cluster-info dump | grep -m1 cluster-cidr`, fix the variable, re-apply.

On EKS the equivalent is the Kafka security group admitting the node security group; pods use
node addresses under the default VPC CNI, so this only breaks if you enabled custom networking
or a different CNI.

### My IP changed; `kubectl` times out and SSH hangs

Every inbound path is allow-listed to your previous `/32`. Rerun:

```bash
bash scripts/operator-cidr.sh
terraform -chdir=terraform/<cloud>/infra apply   # then make CLOUD=<cloud> env
```

This updates the Kafka firewall rule/security group and the Kubernetes API allow-list. On GKE
the change is immediate; on EKS the cluster endpoint update takes **5–10 minutes** and
`kubectl` fails until it finishes. `terraform apply` itself does not need the Kubernetes API
for the infra root, so it succeeds even while you are locked out.

### `kubectl` on EKS: `error: You must be logged in to the server (Unauthorized)`

The cluster uses API authentication mode with an access entry for the identity that ran
Terraform. You are now a different identity (assumed role vs. user, a different profile).
Either switch back or add a second access entry with `aws eks create-access-entry` and
`aws eks associate-access-policy --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy`.

### KubeMQ pods `Pending`, PVC `Pending` on EKS

`kubectl describe pvc` shows `waiting for a volume to be created`. The EBS CSI add-on is not
running or has no permission. Check `kubectl -n kube-system get pods -l app=ebs-csi-controller`
and the Pod Identity association in `terraform output`. The add-on install can lag the node
group by a few minutes; wait, then check again. A PVC also stays Pending if the default
StorageClass is missing: `kubectl get sc` must show `gp3 (default)`.

### `kubectl` works but KubeMQ never reaches 3 Ready pods

`kubectl -n kubemq describe kubemqcluster` — look for a license condition. An online key
needs outbound reach from the pods (NAT); an offline file must be in the Secret under key
`licenseFile`; a key that permits fewer than 3 servers is refused. Then
`kubectl -n kubemq logs <pod>` for the server's own message.

## kmq deploy and auth

### First `kmq auth login` returns `password_change_required`

A freshly installed cluster seeds a one-time administrator password that must be replaced
before any other authenticated call works. A login with `--password-stdin` is refused with
`password_change_required`. Use the bootstrap form, which reads the seeded password from the
cluster and replaces it with the one you supply on standard input:

```bash
printf '%s' "$NEW_ADMIN_PASSWORD" | kmq auth login --installation <id> --all --bootstrap --username admin --new-password-stdin --non-interactive
```

Expect `"state": "authenticated"` with three servers; then `kmq deploy verify` reports
`verified`. Later logins use `--password-stdin` with the new password.

## kmq migrate

### `prepare --apply` returns error code `partial` or a topic with `readback: unconfirmed`

Seen right after the target topics are created on a fresh KubeMQ cluster: the first apply
stopped with `partial` ("target topic audit partition 0 is nonempty or unavailable"), a
second apply recorded one topic as `readback: unconfirmed`, and the third apply with the same
`--approve-hash` returned `"outcome": "prepared"` with every topic `already_matching` /
`confirmed`. The partition leaders of the just-created topics were still being elected when
the read-back ran. Nothing is wrong with the data; re-run the apply with the same hash until
the outcome is `prepared`. If it stays `partial` across several attempts, check
`kubectl -n kubemq get pods` and the server logs for a server that is not Ready.

### `job tool plan` refuses: "migration plan requires at least one source writer"

The declaration's `source_writers` list is empty. kmq v3.6.14 refuses to plan without at
least one named source writer, even in this showcase where nothing writes after the seed.
Name the seeder, `showcase-seeder`, as the source writer and run the plan again (observed:
accepted on the next attempt).

### `job bootstrap` fails with "no installation record" or "no management endpoint"

`job bootstrap` reads the record that `kmq deploy apply` wrote and dials the management API.
If you installed KubeMQ any other way there is no record; reinstall with `kmq deploy`. If the
record has no reachable management address (private management, which this showcase uses),
open the tunnels first in a second terminal and leave it running:

```bash
kmq deploy forward --installation <id> --all
```

### `job submit` refuses: "worker image … is pinned to the authoring kmq"

The `kmq` you are running now is not the version (or build) that authored the plan and the
worker image recorded in `bootstrap.json`. Reinstall the pinned version. There is an
`--allow-version-mismatch` flag; do not use it in this showcase, because the result would not
match the documented flow.

### `job tool plan` refuses the declaration

Run `kmq migrate plan --help` for the exact contract of your binary; the shipped example was
generated with `--print-template` at the pinned version. Fields that trip people: applications
must be non-empty (use the placeholder), `source_writers` must name at least one writer (the
showcase uses `showcase-seeder`),
`max_write_pause_seconds` must be > 0, every `semantics.*.status: none` needs
`evidence_source`, `observed_at` and `inspected_scope`.

### `report` refuses `--target-api`

Expected: `report` is offline and reads only the checkpoint. Drop the flag.

### Worker Job failed or was interrupted mid-replicate

Do not delete the ownership ConfigMap or the Job to force a restart. Run
`kmq migrate job recovery-check --plan migration/plan.json --state-pvc <claim>` to see the
state. Recovery is out of scope for this showcase; for a throwaway rig the practical answer
is to tear down, bring up, re-seed and start again.

## Teardown

### `verify-teardown` lists disks or load balancers Terraform never created

Kubernetes created them: persistent volumes for KubeMQ and the worker (tagged
`goog-gke-volume` or `kubernetes.io/cluster/<name>`), a load balancer if anything created a
`type: LoadBalancer` Service. `scripts/pre-destroy.sh` deletes these *before* the cluster
disappears; if you ran `terraform destroy` directly, the cluster is gone and so is the
controller that would have cleaned them up. Delete by hand with the commands in
[docs/08](08-teardown-and-cost.md#lost-or-corrupted-terraform-state).

### `terraform destroy` hangs on the Kubernetes namespace

The `KubemqCluster` object has a finalizer and the chart marks it `resource-policy: keep`.
`pre-destroy.sh` removes it with `--wait`. If you skipped that step, run
`kubectl -n kubemq delete kubemqcluster --all --wait` and retry the destroy.
