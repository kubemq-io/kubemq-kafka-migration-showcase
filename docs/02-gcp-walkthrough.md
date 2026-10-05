# 02 — GCP walkthrough

The manual path. Every step mirrors a `make` target or a prompt; if you use a coding agent,
hand it `prompts/00-full-run.md` and read this document to know what it is doing. Durations
marked "observed" are from one real run of this repository (2026-10-04, default
500,000-record seed, kmq v3.6.14); the others are estimates. Yours will differ.

**Money starts at step 3.** Steps 1–2 create nothing billable.

## 1. Preflight (5 min, free)

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project "$PROJECT_ID"
cp terraform/gcp/infra/terraform.tfvars.example terraform/gcp/infra/terraform.tfvars
# edit: project_id, region, zone. kafka_version/kafka_sha512 are passed by make from versions.env. Leave operator_cidr to the script below.
cp terraform/gcp/k8s-addons/terraform.tfvars.example terraform/gcp/k8s-addons/terraform.tfvars
# only the license line matters here (cluster identity is passed by make from the infra outputs).
# Remove the kubemq_license_key line if you pass the key through the environment instead, or
# leave both license variables unset when kmq deploy will use a saved kmq license credential:
export TF_VAR_kubemq_license_key='<your key>'     # or kubemq_license_secret_name; both belong to the k8s-addons root
make CLOUD=gcp preflight
```

Preflight checks tools and their minimum versions, `gcloud` auth, the project, the enabled
APIs and the four regional quotas from [docs/00](00-prerequisites.md#quotas). It does not
enumerate IAM roles (clients often cannot list their own policy); the roles you need are in
[docs/00](00-prerequisites.md). Fix every red line before continuing; a quota failure mid-apply
leaves a half-built rig that still bills. Your IPv4 `/32` is written by `scripts/operator-cidr.sh`
into `terraform/gcp/infra/operator.auto.tfvars` as the first step of `make infra-up` (step 3),
not by preflight.

Set the budget alert now if you have not ([docs/00](00-prerequisites.md#budget-alert)).

## 2. Review the plan (2 min, free)

```bash
terraform -chdir=terraform/gcp/infra init && terraform -chdir=terraform/gcp/infra plan
```

Expect roughly: 1 VPC, 1 subnet with two secondary ranges, 1 router + NAT, 8 static addresses
(4 internal + 4 external), 4 VMs, 3 firewall rules, 1 GKE cluster, 1 node pool, 1 readiness
check. The plan prints `hourly_cost_estimate` (≈ $2.50 / hour).

## 3. Infrastructure up (about 25 min observed) — **billing starts**

```bash
make CLOUD=gcp infra-up
```

What happens, in order: `scripts/operator-cidr.sh` writes your `/32` → APIs enabled → network → addresses → Kafka VMs boot and cloud-init
installs Kafka (3–5 min) → GKE cluster and node pool (10–15 min, in parallel) → a readiness
gate SSHes to the driver and waits until `kafka-metadata-quorum.sh describe --status` shows 3
brokers (10 min timeout). The target ends by running `scripts/write-env.sh`, which turns the
Terraform outputs into `.rig/env`.

Observed: 34 resources, about 25 minutes from `plan` to outputs written, with GKE cluster
creation and the Kafka quorum gate dominating.

Gate: `make CLOUD=gcp status` prints `KRaft leader elected`, `3/3 brokers answering on the
INTERNAL listener`, `kcat sees 3 brokers` and ends with `KAFKA RIG OK`. Stop and read
[docs/07](07-troubleshooting.md) if any line is marked ⛔.

## 4. Kubernetes add-ons (under 1 min observed)

```bash
make CLOUD=gcp addons-up
```

Applies `terraform/gcp/k8s-addons`: the `kubemq` namespace, the license Secret (data key
`licenseKey`, from your variable or your pre-created Secret), and a management TLS Secret with
the required names. `.rig/env` now has `LICENSE_SECRET` and `TLS_SECRET`, plus `KUBECONFIG_CMD`
(`gcloud container clusters get-credentials …`), which the prompts run with `eval` to point
`kubectl` at the cluster.

## 5. Seed Kafka (3–5 min for 500k; 10–15 min for 5M)

```bash
make CLOUD=gcp seed                 # RECORDS=500000 default
make CLOUD=gcp seed RECORDS=5000000 # full run
```

Cross-compiles `tools/seed` for Linux, copies it to the driver VM, runs it over the internal
listener. Creates 10 topics × 6 partitions, writes exactly `RECORDS` records of 1,024 bytes
with repeating keys and three headers, commits offsets for the `analytics` (100%), `billing`
(50%) and `archiver` (10%) consumer groups, then verifies counts and under-replicated
partitions. Writes `.rig/seed.env`. A second seed is refused (`topics already exist`);
re-seeding needs `make CLOUD=gcp seed SEED_ARGS=--recreate`, which wipes the topics.

Observed: the produce itself took 1 second for 500,000 records (about 505,000 records per
second) and 9 seconds for 5,000,000 (about 566,000 records per second); the step's minutes
are the cross-compile, the copy to the driver and the verifier.

Gate: the seeder prints `produced <RECORDS>/<RECORDS> … errors=0` and the verifier exits 0.

## 6. Install kmq and KubeMQ (about 10 min observed) — prompt `03-install-kmq-and-kubemq.md`

By hand: `scripts/kmq-install.sh`; fill the `__PLACEHOLDER__` values of
`kubemq/deploy-input.gcp.json` into `.rig/deploy-input.json` (server image from
`kmq deploy prepare --help`, kube context, the two Secret names, the CA file extracted from the
TLS Secret); then `kmq deploy prepare --input .rig/deploy-input.json --out .rig/recipe.json`,
`kmq deploy plan --input .rig/recipe.json --out .rig/plan.json`,
`kmq deploy apply --plan .rig/plan.json`,
`kubectl -n kubemq wait --for=condition=Ready pod/kubemq-0 pod/kubemq-1 pod/kubemq-2 --timeout=20m`,
`kmq deploy forward --installation <id> --all` (kept running), and
`kmq auth login --installation <id> --all --bootstrap --username admin --new-password-stdin --non-interactive`
with a new administrator password of your choice on standard input (the seeded one-time
password is read from the cluster and replaced; a plain `--password-stdin` login returns
`password_change_required`, see [docs/07](07-troubleshooting.md)). The prompt has the exact
`jq` fill. Most of the time is image pulls through NAT and the three servers forming their
cluster: about 10 minutes observed from `kmq deploy prepare` to three Ready pods and
`kmq deploy status` reporting `cluster_ready_needs_authenticated_verification`.

Gate: 3 pods Ready; `kmq deploy status` reports a `cluster_ready*` state; `kmq auth login --all`
reports `authenticated`; `kmq deploy verify` reports `verified`; the installation record
exists (the later `job bootstrap` refuses to run without it).

## 7. Bootstrap, probe, target-check (5 min) — prompt `04-migrate-bootstrap-and-probe.md`

Creates the source profile from `KAFKA_BOOTSTRAP_INTERNAL`, runs a read-only
`kmq migrate assess` from your laptop against `KAFKA_BOOTSTRAP_EXTERNAL`, then
`kmq migrate job bootstrap` to create the worker's resources, and runs `probe` and
`target-check` **as Jobs inside the cluster**. These two are mandatory: a laptop connection
proves nothing about pod-to-broker routing, and `target-check` confirms the strict
acknowledgement policy is actually in effect, not just configured.

Gate: both Jobs print a passing line. If `probe` cannot reach 9092, see the pod-CIDR entry in
[docs/07](07-troubleshooting.md).

## 8. Prepare target topics and plan (2–5 min) — prompt `05-migrate-plan.md`

First `kmq migrate job tool … --tool prepare` twice: a preview that prints an immutable
preparation plan with a hash, then `--apply --approve-hash <hash>` that creates the ten empty
target topics with the source's partition counts (the plan binds each target topic's creation
identity, so they must exist first). On a fresh target the apply may return error code
`partial` or a `readback: unconfirmed` topic while partition leaders are still being elected;
re-run the apply with the same hash until the outcome is `prepared` (observed: third apply,
all 10 topics `already_matching` / `confirmed`). Then merge the scope from
`kubemq/migration/declaration.example.json` into the bootstrap-written `declaration.json`
and run `kmq migrate job tool … --tool plan`. The plan refuses a declaration without a source
writer (`migration plan requires at least one source writer`); name the seeder,
`showcase-seeder`. The plan is immutable; a wrong declaration means a new plan, not an edit.

## 9. Replicate (about 1 min observed for 500k) — prompt `06-migrate-replicate.md`

`kmq migrate job submit --operation replicate …`, then poll `kmq migrate job status` and
`kmq migrate job logs`. Observed on our run: 500,000 records (547,488,900 payload bytes) in
20,361 milliseconds of worker time, about 24,600 records per second and about 26.9 MB per
second; about 1 minute wall clock from submit to completed. Your number will differ; it is
not a capacity figure. The 5,000,000-record run was not timed in this repository.

## 10. Verify and report (3–5 min) — prompt `07-migrate-verify-and-report.md`

`--operation verify` (every copied record compared against the source over the recorded
boundaries), then `--operation report` (offline; no `--target-api`). Observed: verify
reported `total_mapped` 500000 in 7,202 milliseconds of worker time with no unverified
prefix or tail on any of the 60 partitions; the report (generation 3) had
`verification.status` `checkpoint_consistent`. Retrieve `report.json` from the state volume
with the helper pod in the prompt and compare its shape with
`examples/reports/gcp-500k-report.json`. [docs/05](05-reading-the-report.md) explains the
fields.

Gate: verify reports zero mismatches for all 60 partitions. A passing verify certifies
copied history only.

## 11. Teardown (10–15 min) — prompt `08-teardown.md`

```bash
make CLOUD=gcp down
```

Runs `scripts/pre-destroy.sh` (deletes the KubeMQ cluster object, PVCs and any LoadBalancer
Services — Terraform does not know about them), `terraform destroy` in `k8s-addons` then
`infra`, and `scripts/verify-teardown.sh`.

**You are done only when the last line is exactly `TEARDOWN VERIFIED CLEAN`.** Anything else:
read [docs/08](08-teardown-and-cost.md) and clean up by hand. Check the billing console the
next day regardless.

## Time and money summary

| Step | Duration | Billing |
|---|---|---|
| 1–2 preflight + plan | ~7 min | none |
| 3 infra-up | about 25 min observed | starts; ≈ $2.50 / hour from here (Kafka ≈ $1.80, GKE ≈ $0.70) |
| 4–5 addons + seed | 5–10 min (add-ons under 1 min observed) | running |
| 6 KubeMQ install | about 10 min observed | running |
| 7–10 migrate | 15–20 min (500k; copy itself about 1 min observed) | running |
| 11 teardown | 10–15 min | stops at `TEARDOWN VERIFIED CLEAN` |
| **Total** | **about 50–65 min observed** (65 with debugging, about 50 clean) | **about $3 observed** |
