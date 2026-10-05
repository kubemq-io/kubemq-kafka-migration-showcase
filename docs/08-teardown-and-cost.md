# 08 — Teardown and cost

The rig costs about $2.50 (GCP) or $3.20 (AWS) per hour while it exists and about $60–75 per
day if forgotten. Teardown is therefore the most important step in this repository, and it has
exactly one success signal.

## The rule

**Only the literal line `TEARDOWN VERIFIED CLEAN`, printed by `scripts/verify-teardown.sh`,
means nothing is billing.** A successful `terraform destroy`, an empty-looking console, or an
agent saying "teardown complete" does not. The prompts forbid an agent from reporting a
teardown as finished unless it quotes that line verbatim.

## Order

`make CLOUD=<cloud> down` runs these in order and stops at the first failure.

### 1. `scripts/pre-destroy.sh` — remove what Terraform did not create

Kubernetes creates cloud resources on its own: persistent disks for every PVC, load balancers
for every `type: LoadBalancer` Service. Terraform has no record of them. If the cluster is
destroyed first, the controllers that would release them die with it, and the disks and load
balancers keep billing with nothing left to delete them except you, by hand.

The script, in order:

1. `kmq deploy remove --installation <id>` for the installation, if `.rig/kmq.env` holds the id
   (best effort; a non-zero exit is warned about and the script continues).
2. `kubectl -n kubemq delete kubemqcluster --all --wait` — the Helm chart marks the
   `KubemqCluster` object `helm.sh/resource-policy: keep`, so a Helm uninstall leaves the
   cluster running on purpose. It must be deleted explicitly and the operator must finalize
   it.
3. Delete finished Jobs and their completed pods in the namespace (a completed pod still
   holds its claim), then `kubectl delete pvc --all` in the KubeMQ namespace — the three
   server volumes and the worker's state volume. The data is gone at this point; export the
   report first.
4. Delete every `type: LoadBalancer` Service in all namespaces (there should be none; the
   check is cheap).
5. Wait until the backing disks and load balancers are released.

### 2. `terraform destroy` — `k8s-addons` first, then `infra`

Reverse of apply. `k8s-addons` holds the Kubernetes provider resources (namespace, Secrets)
and must go while the cluster still exists. `infra` then removes the cluster, the Kafka VMs,
the addresses, the firewall rules and the network. Project services on GCP are left enabled
(`disable_on_destroy = false`) so that destroying this rig does not break anything else in
your project.

Expected duration: 10–15 minutes on GCP, 15–20 on AWS (NAT gateway and EKS deletions are
slow).

### 3. `scripts/verify-teardown.sh` — re-query the cloud

Trust nothing from the previous two steps. The script asks the cloud API what still exists,
filtering by **two** markers: the showcase label/tag `showcase=kafka-migration` (everything
Terraform created) and the Kubernetes-created tags `goog-gke-volume` / `kubernetes.io/cluster/<name>`
(everything the cluster created). For each category it prints what it found:

| Category | GCP | AWS |
|---|---|---|
| Compute | instances | EC2 instances (not terminated) |
| Disks | persistent disks | EBS volumes |
| Network rules | firewall rules | security groups |
| Load balancers | forwarding rules, backend services | load balancers (NLB/CLB), target groups |
| Addresses | static addresses (reserved ones bill) | Elastic IPs (unassociated ones bill) |
| NAT | Cloud NAT routers | NAT gateways (not deleted) |
| Kubernetes | clusters | EKS clusters |

Empty everywhere → prints `TEARDOWN VERIFIED CLEAN`, exits 0. Anything found → prints each
item with its estimated hourly cost, exits 1. Run it as many times as you like; it never
deletes.

## Lost or corrupted Terraform state

State is local by default. If `.tfstate` is gone or wrong, `terraform destroy` cannot help.
Clean up by label, then run `verify-teardown.sh` until it is clean.

**GCP** — list first, then delete what the list shows:

```bash
P=$PROJECT_ID; F='labels.showcase=kafka-migration'
gcloud compute instances list        --project $P --filter="$F" --format='value(name,zone)'
gcloud compute disks list            --project $P --filter="$F OR labels.goog-gke-volume:*" --format='value(name,zone)'
gcloud compute addresses list        --project $P --filter="$F" --format='value(name,region)'
gcloud compute firewall-rules list   --project $P --filter="network ~ kmq-showcase" --format='value(name)'
gcloud compute forwarding-rules list --project $P --format='value(name,region)'
gcloud compute routers list          --project $P --filter="network ~ kmq-showcase" --format='value(name,region)'
gcloud container clusters list       --project $P --filter="resourceLabels.showcase=kafka-migration" --format='value(name,location)'
gcloud compute networks list         --project $P --filter="name ~ kmq-showcase"
```

Delete in this order: cluster → instances → disks → forwarding rules → addresses → firewall
rules → router (NAT) → subnet → network. GKE node disks carry `goog-gke-volume` and often
survive a cluster delete; they are the usual leftover.

**AWS:**

```bash
T='Name=tag:showcase,Values=kafka-migration'
aws ec2 describe-instances        --filters "$T" --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table
aws ec2 describe-volumes          --filters "$T" --query 'Volumes[].[VolumeId,State]' --output table
aws ec2 describe-volumes          --filters 'Name=tag-key,Values=kubernetes.io/cluster/*' --query 'Volumes[].[VolumeId,State]' --output table
aws ec2 describe-addresses        --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output table
aws ec2 describe-nat-gateways     --filter "$T" --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' --output table
aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerArn,LoadBalancerName]' --output table
aws eks list-clusters
aws ec2 describe-security-groups  --filters "$T" --query 'SecurityGroups[].[GroupId,GroupName]' --output table
aws ec2 describe-vpcs             --filters "$T" --query 'Vpcs[].VpcId' --output text
```

Delete in this order: EKS node group → EKS cluster → instances → volumes → load balancers →
NAT gateway (wait for `deleted`) → release Elastic IPs → security groups → subnets → internet
gateway (detach first) → VPC. The IAM roles Terraform created (`kmq-showcase-*`) do not bill
but should be removed with `aws iam list-roles --query "Roles[?starts_with(RoleName,'kmq-showcase')]"`.

Unassociated Elastic IPs and detached EBS volumes are silent: they do not appear in any
"running" view and they bill every hour.

## Cost table (estimates)

List prices, on-demand, typical US region, rounded. Verify with your own calculator.

| | GCP | AWS |
|---|---|---|
| 3 Kafka brokers | n2-standard-8 + 375 GB local SSD ≈ $1.35 / h | i4i.2xlarge ≈ $2.05 / h |
| Driver VM | n2-standard-8 ≈ $0.40 / h | m6i.2xlarge ≈ $0.40 / h |
| 3 Kubernetes nodes | n2-standard-4 ≈ $0.60 / h | m6i.xlarge ≈ $0.60 / h |
| Control plane | ≈ $0.10 / h | ≈ $0.10 / h |
| NAT, static IPs, 200 GB persistent disk | ≈ $0.05–0.10 / h | ≈ $0.05–0.10 / h + NAT data processing |
| **Running total** | **≈ $2.50 / h** | **≈ $3.20 / h** |
| Full run, 50–95 min | ≈ $3–5 | ≈ $4–6 |
| Forgotten for a day | ≈ $60 | ≈ $77 |
| Forgotten for a month | ≈ $1,800 | ≈ $2,300 |
| Leftover after bad teardown: 3 × 50 GiB + 1 × 20 GiB disks + 5 addresses | ≈ $15 / month | ≈ $35 / month (EIPs dominate) |

A budget alert ([docs/00](00-prerequisites.md#budget-alert)) lags by hours and stops nothing.
Check the billing console the day after a run even when teardown printed clean.
