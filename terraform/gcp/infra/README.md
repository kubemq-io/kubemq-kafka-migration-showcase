# terraform/gcp/infra

Root 1 of 2 for GCP. Creates the project services, a dedicated VPC with Cloud NAT,
the Kafka cluster (3 brokers + 1 driver VM) and the GKE cluster. Root 2
(`../k8s-addons`) adds the KubeMQ namespace and Secrets and must be applied after this one.

## Apply order

1. `scripts/operator-cidr.sh` writes `operator.auto.tfvars` with your public IPv4 as a `/32`.
   Only that address can reach SSH, Kafka port 9094 and the Kubernetes API.
   `operator_cidr` has no default and refuses `0.0.0.0/0` and anything wider than `/8`.
2. Copy `terraform.tfvars.example` to `terraform.tfvars`, fill in `project_id`, `region`,
   `zone`, `kafka_sha512` (from `versions.env`).
3. `terraform init && terraform apply`. The apply ends with a readiness gate that waits up to
   10 minutes for the Kafka quorum (3 brokers registered) over SSH to the driver.
4. `cd ../k8s-addons && terraform apply` with your license key.

Normally driven by `make CLOUD=gcp infra-up` and `make CLOUD=gcp addons-up`.

## Destroy order

1. `scripts/pre-destroy.sh` (removes KubeMQ custom resources, PVCs and LoadBalancer Services
   that Terraform does not know about).
2. `terraform destroy` in `../k8s-addons`.
3. `terraform destroy` here.
4. `scripts/verify-teardown.sh` — only `TEARDOWN VERIFIED CLEAN` means nothing is billing.

`make CLOUD=gcp down` runs these in order. Project services stay enabled on destroy.

## Notes

- Your public IP changed: rerun `scripts/operator-cidr.sh`, then `terraform apply` here.
- Brokers keep Kafka data on local SSD. Any broker replacement, stop or Spot preemption
  wipes it; re-run the seed. Terraform ignores metadata and image changes so a re-apply
  never replaces a broker on its own.
- SSH: by default the driver is reached with `gcloud compute ssh`. Set `ssh_user` and
  `ssh_public_key_path` to use plain `ssh` instead.
