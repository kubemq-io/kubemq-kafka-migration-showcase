# terraform/aws/infra

Creates, in one `apply`:

- a dedicated VPC (`10.10.0.0/16` by default) with two public and two private
  subnets across two availability zones, an internet gateway and one NAT gateway;
- 3 Apache Kafka (KRaft) brokers on `i4i.2xlarge` (local NVMe for data) and one
  `m6i.2xlarge` driver VM, all in the public subnet of `preferred_az`, each with a
  fixed private IP and an elastic IP;
- an EKS cluster (`1.34` by default) with a 3-node `m6i.xlarge` managed node group
  in the private subnet of `preferred_az`, API-mode authentication with a
  cluster-admin access entry for the caller, and the EBS CSI driver via Pod Identity.

Apply order: this root, then `terraform/aws/k8s-addons` (which needs the cluster
to exist before the Kubernetes provider can be configured).

## Inputs you must set

| Variable | Meaning |
|---|---|
| `region` | AWS region |
| `preferred_az` | zone for Kafka VMs and worker nodes; `i4i.2xlarge` must be offered there (checked at plan) |
| `operator_cidr` | your public IPv4 `/32`; opens SSH, Kafka 9094 and the Kubernetes API. Refuses `0.0.0.0/0` and anything wider than `/8`. Normally written by `scripts/operator-cidr.sh` |
| `kafka_version`, `kafka_sha512` | from `versions.env` |
| `ssh_public_key_path`, `ssh_private_key_path` | key pair installed on every VM as user `ubuntu` |

See `terraform.tfvars.example` for the rest.

## Network rules

- Brokers: 9092-9094 from inside the VPC and between brokers; 22 and 9094 from
  `operator_cidr`; 9092 and 9094 from the EKS node security group.
- Driver: 22 from `operator_cidr`; everything from the brokers.
- Kubernetes API: public endpoint limited to `operator_cidr`, private endpoint for nodes.

## Readiness gate

The apply only finishes when, over SSH to the driver, `kafka-metadata-quorum.sh
describe --status` succeeds and three brokers answer (10 minute limit). If it
times out, the error prints the `journalctl` command to run on the driver.

## Things to know

- `use_spot` is accepted but ignored. Brokers keep their data on instance-store
  NVMe, which is wiped on any stop or interruption, so they are always on-demand.
- A replaced broker comes back empty and must be re-seeded. The module ignores
  AMI and user-data drift so a routine `apply` never replaces one.
- Changing `operator_cidr` and re-applying updates the security groups and the
  EKS public endpoint allow-list; the EKS update takes 5-10 minutes.
- Cost: see `terraform output hourly_cost_estimate` (static list-price estimate).
- Tear down with `make CLOUD=aws down`; it destroys `k8s-addons` first, then this
  root, then re-queries AWS for anything still billing.
