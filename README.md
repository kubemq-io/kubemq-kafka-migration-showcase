# Kafka → KubeMQ migration showcase

Copy a real Apache Kafka cluster's data into a KubeMQ cluster with the `kmq` command-line
tool, and verify every record arrived — driven end to end by a coding agent (Claude Code,
Cursor, GitHub Copilot, Codex) reading plain-markdown prompts.

You bring a Google Cloud or AWS account and a KubeMQ license key. This repository brings:

- Terraform that builds a dedicated network, a 3-broker Apache Kafka 4.x (KRaft) cluster plus
  a driver VM, and a managed Kubernetes cluster (GKE or EKS) in the same network.
- A seeder that fills Kafka with keyed, headered records across 10 topics and 60 partitions,
  with 3 consumer groups holding committed offsets (500,000 records by default; 5,000,000 for
  a full run).
- Prompts that walk an agent through `kmq deploy` (install a 3-server KubeMQ cluster) and
  `kmq migrate` (bootstrap → probe → target-check → prepare → plan → replicate → verify → report), with
  the migration worker running as Kubernetes Jobs inside the target cluster.
- A teardown that destroys everything and then re-queries the cloud to prove nothing is still
  billing.

> **What this showcase proves / does not prove**
>
> It proves that `kmq migrate` can copy a bounded, known Kafka data set into KubeMQ and that
> `kmq migrate verify` can compare every copied record against its source. The verify step
> certifies **copied history only**: it does not certify records written after the copy, and
> it is not an application cutover. `kmq migrate job status` is a bounded observation, not an
> authoritative report. The throughput numbers in the reference report (500,000 records copied
> in about 20 seconds of worker time, verified in about 7 seconds, on GCP) were observed on
> one run of one rig and are not capacity guarantees. The `kmq migrate` command surface is
> development-grade and has not been
> qualified for production migrations. Amazon MSK, Confluent Cloud and authenticated Kafka
> sources are not covered. Recovery after a worker interruption is referenced in the docs but
> not exercised here.

## Prerequisites

Summary; details and exact commands are in [docs/00-prerequisites.md](docs/00-prerequisites.md).

- A GCP project or an AWS account you can create networks, VMs, Kubernetes clusters and IAM
  roles in, with quota for about 48 vCPUs, 3 local-SSD / instance-store VMs and 6 public IPs.
- A KubeMQ license key that permits at least 3 Kubernetes servers (see
  [kubemq.io](https://kubemq.io) — the free standalone-container evaluation does not apply to
  Kubernetes).
- Laptop tools: Terraform ≥ 1.6 or OpenTofu 1.12, `gcloud` or `aws`, `kubectl`, `helm`, `jq`,
  Go ≥ 1.26, `kcat`, bash ≥ 4, and `curl` with IPv4 support. `make CLOUD=gcp preflight` checks all of
  them and prints install hints.
- A coding agent that can run shell commands, or the patience to run the prompts by hand.

## Quick path

```bash
cp terraform/gcp/infra/terraform.tfvars.example terraform/gcp/infra/terraform.tfvars             # edit project_id, region, zone (Kafka pins come from versions.env via make)
cp terraform/gcp/k8s-addons/terraform.tfvars.example terraform/gcp/k8s-addons/terraform.tfvars   # only if you set a license here; cluster identity comes from the infra outputs via make
export TF_VAR_kubemq_license_key='...'           # the license variables belong to the k8s-addons root; or set kubemq_license_secret_name instead

make CLOUD=gcp preflight     # tools, auth, APIs, quotas; nothing is created
make CLOUD=gcp infra-up      # money starts here: VPC, Kafka VMs, GKE (about 25 min observed)
make CLOUD=gcp addons-up     # namespace, license Secret, TLS Secret
make CLOUD=gcp seed          # 500k records into Kafka (RECORDS=5000000 for a full run)

# Hand prompts/03 … prompts/07 to your coding agent, in order:
#   03 kmq deploy prepare → plan → apply --plan → forward → auth login
#   04 kafka profile → assess → job bootstrap → in-cluster probe + target-check
#   05 in-cluster prepare (target topics) → declaration → in-cluster plan
#   06 replicate   07 verify → report → copy report.json out of the state volume
# Or run prompts/00-full-run.md, which orchestrates 01–08 and stops at every gate.

make CLOUD=gcp down          # pre-destroy cleanup → terraform destroy → verify-teardown
```

Replace `gcp` with `aws` for the AWS path. Each prompt is self-contained and starts with a
mandatory safety header; see [prompts/README.md](prompts/README.md).

## Cost and time

Hourly figures are list-price estimates for the default machine types, on-demand, in a
typical US region. The GCP durations and the GCP run cost are what we observed on one real
run of this repository (2026-10-04, default 500,000-record seed); the AWS column is an
estimate. Your bill depends on region, discounts, how long you leave the rig up, and egress.
Check your own pricing calculator before running.

| Item | GCP | AWS (estimate) |
|---|---|---|
| Kafka: 3 brokers + driver | ≈ $1.80 / hour (n2-standard-8 + local SSD) | ≈ $2.50 / hour (i4i.2xlarge + driver) |
| Kubernetes nodes: 3× | ≈ $0.60 / hour (n2-standard-4) | ≈ $0.60 / hour (m6i.xlarge) |
| Kubernetes control plane | ≈ $0.10 / hour | ≈ $0.10 / hour |
| NAT gateway, static IPs, disks | a few cents per hour | a few cents per hour, plus NAT data processing |
| **Total while running** | **≈ $2.50 / hour** | **≈ $3.20 / hour** |
| Infrastructure up (`infra-up`) | about 25 min observed | 20–35 min (EKS is slower) |
| KubeMQ install (prompt 03) | about 10 min observed | 10–20 min |
| Copy of 500,000 records (replicate) | about 1 min wall clock observed | not measured |
| Full run (500k seed), wall clock | about 50–65 min observed (65 with debugging; about 50 clean) | 70–95 min |
| Full run, cost | about $3 observed | ≈ $4–6 |
| **Forgotten rig, per day** | **≈ $60+** | **≈ $75+** |

A forgotten rig is the real cost risk. Set a budget alert before your first run
(instructions in [docs/00-prerequisites.md](docs/00-prerequisites.md#budget-alert)) and always
finish with `make CLOUD=<cloud> down`.

## Tested with

| Component | Version |
|---|---|
| `kmq` command-line tool | v3.6.14 (exact pin in `versions.env`) |
| Apache Kafka | 4.3.1 (Scala 2.13), KRaft mode |
| Terraform / OpenTofu | Terraform ≥ 1.6, OpenTofu 1.12 |
| KubeMQ Helm chart, operator and server | the versions `kmq deploy prepare` pins at v3.6.14 (chart 3.4.0, server image `kubemq-next` v3.6.14 on the reference run); not hard-coded here |
| Kubernetes | GKE regular channel, EKS 1.30+ |
| Brokers | Ubuntu 24.04 LTS |

The migration worker image must match the `kmq` version that authored the plan;
`kmq migrate job submit` refuses a mismatch. Change `KMQ_VERSION` only together with a fresh
`kmq deploy` and a regenerated `kubemq/migration/declaration.example.json`.

## Repository layout

```
versions.env          exact pins: kmq, Kafka tarball + SHA-512, Terraform, kcat
Makefile              preflight, cidr, infra-up, addons-up, env, seed, status, kmq-install, kubemq-install,
                      pre-destroy, down, verify-teardown, leak-scan, lint
docs/                 00 prerequisites · 01 architecture · 02 GCP walkthrough · 03 AWS walkthrough
                      04 migration flow · 05 reading the report · 06 what success looks like
                      07 troubleshooting · 08 teardown and cost
prompts/              _header.md (mandatory block) · 00 orchestrator · 01–08 one prompt per step
terraform/            modules/ (network, kafka, gke, eks, k8s-addons) · gcp/{infra,k8s-addons} · aws/{infra,k8s-addons}
scripts/              preflight, operator-cidr, kafka node scripts (cloud-init), seed, write-env,
                      kmq-install, pre-destroy, verify-teardown, leak-scan
tools/seed/           Go seeder (franz-go), cross-compiled and copied to the driver VM
kubemq/               kmq deploy input per cloud · migration/declaration.example.json
examples/reports/     the unedited report of one real 500,000-record GCP run + explained.md
```

## Teardown — read this before `infra-up`

`make CLOUD=<cloud> down` runs three steps in order: `scripts/pre-destroy.sh` (deletes the
KubeMQ cluster object, its persistent volume claims and any LoadBalancer Services, because
Terraform did not create them and cannot remove them), `terraform destroy` for both roots, and
`scripts/verify-teardown.sh`, which re-queries the cloud for anything still carrying the
showcase label or a Kubernetes-created tag.

**Only the literal line `TEARDOWN VERIFIED CLEAN` means nothing is billing.** Any other
output — a non-zero exit, a listed resource, a timeout — means something is still running and
you must fix it by hand. The prompts enforce the same rule: an agent may never report a
teardown as done unless it has quoted that exact line. See
[docs/08-teardown-and-cost.md](docs/08-teardown-and-cost.md) for recovery when Terraform
state is lost.

## License

Apache License 2.0 — see [LICENSE](LICENSE). KubeMQ server, operator and chart images are
licensed separately under their own terms; a KubeMQ license key is required and is not
included.
