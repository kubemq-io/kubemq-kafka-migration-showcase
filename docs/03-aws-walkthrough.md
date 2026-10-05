# 03 — AWS walkthrough

The manual path on AWS. Same sequence as GCP; the differences are called out. If you use a
coding agent, hand it `prompts/00-full-run.md` and answer `aws` when it asks for `CLOUD`.

**Money starts at step 3.**

## 1. Preflight (5 min, free)

```bash
export AWS_PROFILE=<profile>
export AWS_REGION=<region>
aws sts get-caller-identity
cp terraform/aws/infra/terraform.tfvars.example terraform/aws/infra/terraform.tfvars
# edit: region, preferred_az, aws_profile. kafka_version/kafka_sha512 are passed by make from versions.env. Leave operator_cidr to the script.
cp terraform/aws/k8s-addons/terraform.tfvars.example terraform/aws/k8s-addons/terraform.tfvars
# only the license line matters here (region and cluster name are passed by make from the infra outputs).
# Remove the kubemq_license_key line if you pass the key through the environment, or leave both
# license variables unset when kmq deploy will use a saved kmq license credential:
export TF_VAR_kubemq_license_key='<your key>'     # or kubemq_license_secret_name; both belong to the k8s-addons root
make CLOUD=aws preflight
```

Preflight checks tools and their minimum versions, `aws` auth, the region, the on-demand
vCPU quota (`L-1216C47A` ≥ 48) and the Elastic IP quota (`L-0263D0A3` ≥ 5). It does not check
that `i4i.2xlarge` is offered in your region; Terraform fails at apply time if it is not. Your
IPv4 `/32` is written to `terraform/aws/infra/operator.auto.tfvars` by `scripts/operator-cidr.sh`
as the first step of `make infra-up`, not by preflight.

Set the budget alert now ([docs/00](00-prerequisites.md#budget-alert)).

## 2. Review the plan (2 min, free)

```bash
terraform -chdir=terraform/aws/infra init && terraform -chdir=terraform/aws/infra plan
```

Expect roughly: 1 VPC, 2 public + 2 private subnets (EKS control plane needs two availability
zones; Kafka and the nodes land in one of them), 1 internet gateway, 1 NAT gateway, 5 Elastic
IPs (3 brokers, driver, NAT), 4 instances with pre-created network interfaces, 3 security
groups, 1 EKS cluster with an access entry for your identity, 1 managed node group, and the
EBS CSI add-on with a Pod Identity association (the `gp3` default StorageClass comes from the
`k8s-addons` root in step 4). `hourly_cost_estimate` ≈ $3.20 / hour.

## 3. Infrastructure up (20–35 min) — **billing starts**

```bash
make CLOUD=aws infra-up
```

EKS control plane creation alone takes 10–15 minutes; the node group another 3–5. Kafka
instances boot in parallel; user-data installs Kafka and mounts the instance-store NVMe
(matched by model string `Amazon EC2 NVMe Instance Storage`). The readiness gate waits for a
3-broker quorum via the driver.

Gate: `make CLOUD=aws status` prints `KRaft leader elected`, `3/3 brokers answering on the
INTERNAL listener`, `kcat sees 3 brokers` and ends with `KAFKA RIG OK`.

## 4. Kubernetes add-ons (2 min)

```bash
make CLOUD=aws addons-up
```

Applies `terraform/aws/k8s-addons`: namespace, license Secret (data key `licenseKey`),
management TLS Secret, and the `gp3` default StorageClass. `.rig/env` gets `KUBECONFIG_CMD` (`aws eks update-kubeconfig …`), which
the prompts run with `eval`. If `kubectl` is then denied, your caller identity differs from the
one Terraform recorded in the access entry; see [docs/07](07-troubleshooting.md).

## 5. Seed Kafka (3–5 min for 500k; 10–15 min for 5M)

```bash
make CLOUD=aws seed
```

Identical to GCP. The seeder runs on the driver over private IPs.

## 6. Install kmq and KubeMQ (10–20 min) — prompt `03-install-kmq-and-kubemq.md`

Uses `kubemq/deploy-input.aws.json` (storage class `gp3`). Everything else matches GCP. If
KubeMQ pods stay `Pending` with a PVC that never binds, the EBS CSI add-on is not healthy;
see [docs/07](07-troubleshooting.md).

## 7–10. Bootstrap, probe, target-check, prepare target topics, plan, replicate, verify, report

Prompts `04` through `07`, exactly as on GCP (steps 7–10 in [docs/02](02-gcp-walkthrough.md)).
On AWS the worker reaches Kafka's internal listener because the Kafka security group admits
the EKS node security group on 9092 and 9094; pod traffic leaves the node with the node's
address under the default VPC CNI, so no separate pod-CIDR rule is needed.

## 11. Teardown (15–20 min) — prompt `08-teardown.md`

```bash
make CLOUD=aws down
```

AWS teardown is slower than GCP: the NAT gateway takes several minutes to delete, and an
EKS cluster cannot be deleted until its node group is gone. `scripts/pre-destroy.sh` matters
more here — an orphaned LoadBalancer Service would leave a network load balancer and its
Elastic IP billing after `terraform destroy` succeeds. `scripts/verify-teardown.sh`
re-queries instances, EBS volumes (including those tagged `kubernetes.io/cluster/<name>`),
security groups, load balancers, Elastic IPs and NAT gateways.

**You are done only when the last line is exactly `TEARDOWN VERIFIED CLEAN`.** Unassociated
Elastic IPs bill by the hour; they are the most common leftover.

## Time and money summary

| Step | Duration | Billing |
|---|---|---|
| 1–2 preflight + plan | ~7 min | none |
| 3 infra-up | 20–35 min | starts; ≈ $3.20 / hour from here |
| 4–5 addons + seed | 5–10 min | running |
| 6 KubeMQ install | 10–20 min | running |
| 7–10 migrate | 15–20 min (500k) | running |
| 11 teardown | 15–20 min | stops at `TEARDOWN VERIFIED CLEAN` |
| **Total** | **70–95 min** | **≈ $4–6** |
