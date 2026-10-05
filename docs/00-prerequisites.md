# 00 — Prerequisites

Everything you need before `make CLOUD=<cloud> preflight` can pass. Nothing in this document
creates billable resources.

## Accounts

- **GCP:** a project you own or administer, with billing enabled. Fresh projects work; the
  default quotas usually do not (see [Quotas](#quotas)).
- **AWS:** an account (or an organization member account) with billing enabled, and a profile
  configured in `~/.aws/config` that `aws sts get-caller-identity` resolves.
- **KubeMQ:** a license key or signed license file that permits at least 3 Kubernetes
  servers. See [KubeMQ license](#kubemq-license).

## IAM roles

Terraform creates networks, firewall rules, VMs, static addresses, a Kubernetes cluster and
service-account bindings. Your identity needs the following.

**GCP** (grant on the project to the user or service account running Terraform):

| Role | Why |
|---|---|
| `roles/compute.admin` | VMs, disks, static addresses |
| `roles/compute.networkAdmin` | VPC, subnets, Cloud NAT, firewall rules |
| `roles/container.admin` | GKE cluster and node pool |
| `roles/iam.serviceAccountUser` | let GKE nodes and VMs run as the default compute service account |
| `roles/serviceusage.serviceUsageAdmin` | enable the APIs below from Terraform |

`roles/owner` or `roles/editor` also work but are wider than needed.

**AWS:** `AdministratorAccess` on the account is the simplest option for a throwaway rig. If
your organization requires a scoped policy, it must allow full `ec2:*` (VPC, subnets, NAT
gateway, security groups, instances, Elastic IPs, volumes), `eks:*`, `iam:CreateRole`,
`iam:AttachRolePolicy`, `iam:PassRole`, `iam:CreateOpenIDConnectProvider`,
`iam:TagRole`, `iam:GetRole`, `iam:DeleteRole`, `iam:DetachRolePolicy`, plus
`sts:GetCallerIdentity`. EKS creates a cluster role and a node role; EBS CSI via Pod Identity
creates a third.

## APIs to enable (GCP)

Terraform enables these too, but doing it once by hand avoids a half-applied first run:

```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicenetworking.googleapis.com \
  --project "$PROJECT_ID"
```

AWS services need no enabling.

## Quotas

The default rig is 3 Kafka brokers (8 vCPU each), 1 driver (8 vCPU) and 3 Kubernetes nodes
(4 vCPU each) = 44 vCPUs, plus 3 local-SSD/instance-store disks and 6 public IP addresses
(3 brokers, driver, NAT, cluster endpoint). Preflight checks the following and tells you
which one is short.

**GCP** (per region; check with `gcloud compute regions describe REGION --format='value(quotas)'`):

| Quota | Needed | Fresh-project default (typical) |
|---|---|---|
| `CPUS` and `N2_CPUS` | ≥ 48 | 24 — you will need an increase |
| `LOCAL_SSD_TOTAL_GB` | ≥ 1125 (3 × 375 GB) | often 0 or 1500 depending on project age |
| `IN_USE_ADDRESSES` | ≥ 6 | 8 |

Request increases in the console: IAM & Admin → Quotas & System Limits → filter by the quota
name and region → Edit quotas. Increases on fresh projects can take minutes to two business
days. Ask for `N2_CPUS` = 64 to leave headroom.

**AWS** (per region):

| Quota | Code | Needed | Default |
|---|---|---|---|
| Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances (vCPUs) | `L-1216C47A` | ≥ 48 | often 5–32 on new accounts |
| EC2-VPC Elastic IPs | `L-0263D0A3` | ≥ 5 | 5 |

Check: `aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A`.
Request: `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-1216C47A --desired-value 64`,
or Service Quotas in the console. `i4i.2xlarge` is not offered in every availability zone;
you choose the zone with `preferred_az` in `terraform.tfvars`, and Terraform refuses at plan time
if the type is not offered there.

## Tools

`scripts/preflight.sh` checks every item below and prints the install hint for the one that is
missing. Versions are pinned in `versions.env`.

| Tool | macOS (Homebrew) | Debian / Ubuntu |
|---|---|---|
| Terraform ≥ 1.6 **or** OpenTofu 1.12 | `brew install opentofu` (or `brew tap hashicorp/tap && brew install hashicorp/tap/terraform`) | HashiCorp or OpenTofu apt repository |
| bash ≥ 4 | `brew install bash` (macOS ships 3.2; the scripts refuse it) | already ≥ 5 |
| `gcloud` + `gke-gcloud-auth-plugin` | `brew install --cask google-cloud-sdk && gcloud components install gke-gcloud-auth-plugin` | Google Cloud apt repository |
| `aws` CLI v2 | `brew install awscli` | `apt install awscli` or the official installer |
| `kubectl` | `brew install kubectl` | `apt install kubectl` (Kubernetes apt repository) |
| `helm` ≥ 3 (used by `kmq deploy`) | `brew install helm` | `apt install helm` (Helm apt repository) |
| `jq` | `brew install jq` | `apt install jq` |
| Go ≥ 1.26 (to cross-compile the seeder; `GO_MIN` in `versions.env`) | `brew install go` | `apt install golang-go` or go.dev tarball |
| `kcat` (or `nc` as fallback) | `brew install kcat` | `apt install kafkacat` |
| `curl` with IPv4 (`curl -4`) | built in | built in |
| `ssh`, `scp` | built in | built in |

Authenticate before preflight: `gcloud auth login && gcloud auth application-default login`
for GCP; `aws sso login` or static keys in a profile for AWS.

## KubeMQ license

A KubeMQ cluster on Kubernetes requires a license. The free standalone-container evaluation does
not apply. Contact KubeMQ via [kubemq.io](https://kubemq.io) for an evaluation license that
permits at least 3 Kubernetes servers; say that you intend to run the Kafka migration showcase
so the key is sized for three servers.

Two forms exist:

- **Online key** (`licenseKey`): the server activates the key against KubeMQ's licensing
  service and keeps a lease. The KubeMQ pods therefore need outbound internet from the cluster.
  Both Terraform roots give the private nodes a NAT gateway, so this works by default. If your
  organization blocks egress, ask for an offline file instead.
- **Offline signed file** (`licenseFile`): verified locally, no network needed.

Terraform's `k8s-addons` root creates a Secret in the KubeMQ namespace from one of:

- `kubemq_license_key` (sensitive variable, pass with `TF_VAR_kubemq_license_key` or a
  `*.auto.tfvars` that you never commit) → Secret key `licenseKey`, or
- `kubemq_license_secret_name` — the name of a Secret you created yourself with key
  `licenseKey` (online) or `licenseFile` (offline):

  ```bash
  kubectl -n kubemq create secret generic my-kubemq-license --from-literal=licenseKey='<key>'
  # or
  kubectl -n kubemq create secret generic my-kubemq-license --from-file=licenseFile=./kubemq.license
  ```

  The shipped recipe templates (`kubemq/deploy-input.<cloud>.json`) name the data key
  `licenseKey` with `kind: key`. For an offline file change them to `licenseFile` and
  `kind: file` before prompt 03 (see `kubemq/README.md`).

Set exactly one of the two variables. The KubeMQ chart refuses to render unless exactly one
license source is configured, and the license may cap the server count, so a key that allows
fewer than 3 servers fails at `kmq deploy apply` with a clear message rather than silently
running fewer servers.

## kmq install

`scripts/kmq-install.sh` installs the pinned version from the public release:

```bash
curl -sSfL https://raw.githubusercontent.com/kubemq-io/kmq/main/install.sh | sh -s -- --version "$KMQ_VERSION"
kmq version
```

The script refuses to continue when `kmq version` does not match `KMQ_VERSION` in
`versions.env`. Do not upgrade `kmq` mid-run: the migration worker image is pinned to the
version that authored the plan.

## Budget alert

Terraform does not create budgets; most client identities lack billing permissions. Do this
once by hand, before the first `infra-up`.

**GCP:** Billing → Budgets & alerts → Create budget → scope: your project → amount: $50 →
thresholds 50%, 90%, 100% → email to yourself. Alerts are not real-time; they can lag by hours.

**AWS:** Billing and Cost Management → Budgets → Create budget → Cost budget → monthly, $50
→ alert at 80% actual and 100% forecasted → your email. Also turn on "Receive Free Tier usage
alerts" and consider an AWS Budgets action that denies `ec2:RunInstances` at 100%.

Neither alert stops anything. The only stop is `make CLOUD=<cloud> down` and the literal
`TEARDOWN VERIFIED CLEAN` line.

## Your operator IP (`operator_cidr`)

The Kafka brokers' external listener (port 9094), SSH to the driver, and the Kubernetes API
endpoint are reachable from **one IPv4 address only**: yours, as a `/32` (a single address).
`scripts/operator-cidr.sh` detects it with `curl -4` (the `-4` matters: on a dual-stack
connection the detection services otherwise answer with your IPv6 address, which the firewall
cannot use) and writes it to `operator.auto.tfvars`. The variable has no default; Terraform
refuses `0.0.0.0/0` and anything wider than `/8`.

If your address changes (new network, VPN on/off), rerun `scripts/operator-cidr.sh` and
`terraform apply` in the infra root. The firewall rule and the Kubernetes API allow-list are
replaced, never widened. On EKS the endpoint update takes 5–10 minutes.
