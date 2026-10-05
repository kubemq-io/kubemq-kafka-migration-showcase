# 01 — Infrastructure up

## Rules for this session (mandatory — read before running anything)

1. **Cost gate.** Before any command that creates cloud resources, print what will be created
   and the hourly cost estimate, then stop and wait for an explicit "yes" from the operator.
   Do not proceed on silence or on a general "go ahead" given earlier in the conversation.
2. **Red is red.** A non-zero exit code, or any output line containing `FAIL`, `⛔`, `failed`,
   `not_ready`, `failed_blocked` or `BLOCKED`, is a failure. Quote the exact line verbatim.
   Never paraphrase a failure as a success or a "minor warning".
3. **Only one sentence means clean.** Only the literal line `TEARDOWN VERIFIED CLEAN`, printed
   by `make CLOUD=$CLOUD verify-teardown`, means nothing is still billing. No other output,
   including a successful `terraform destroy`, means that.
4. **Final message.** Your last message in this session must state whether cloud resources
   are still running and the hourly cost from `.rig/env` (`HOURLY_COST`). If you do not know,
   say "unknown — run prompt 08".
5. **Verify is not cutover.** A passing `verify` certifies that the copied history matches the
   source over the recorded boundaries. It does not certify later source writes, consumer-group
   offsets on the target, application behavior, or a cutover.
6. **Never invent flags.** Before the first `kmq` command of a step, run `kmq skills get core`
   once and `kmq <command> --help` for each command you are about to use. If a flag in this
   prompt does not appear in `--help`, stop and report the difference instead of guessing.
7. **State lives in files, not in memory.** Read cloud state from `.rig/env`, seed state from
   `.rig/seed.env`, installer state from `.rig/kmq.env`. Re-read them at the start of every
   step; never rely on values remembered from earlier in the conversation.

## Inputs

- `CLOUD` — `gcp` or `aws`, from the operator.
- Terraform variables in `terraform/$CLOUD/infra/terraform.tfvars` (copied from the
  `.tfvars.example` next to it): project or AWS profile, region and zone, machine types.
  `kafka_version` and `kafka_sha512` are passed by `make` from `versions.env`.
- Terraform variables in `terraform/$CLOUD/k8s-addons/terraform.tfvars` (copied from its
  `.tfvars.example`): only the license, if Terraform is to create the Secret (either
  `kubemq_license_key` or `kubemq_license_secret_name`, never both; the key may also be passed
  as `TF_VAR_kubemq_license_key`). Leave both unset when `kmq deploy` will create the Secret
  from a saved kmq license credential (`kmq license list`). Cluster identity is passed by `make`
  from the infra outputs.
- `operator_cidr` is **not** typed by hand; `scripts/operator-cidr.sh` detects your IPv4 /32
  and writes it. It has no default and the Terraform validation refuses `0.0.0.0/0`.

## Preconditions

- `make CLOUD=$CLOUD preflight` exits 0 (tools, cloud login, enabled APIs, quotas).
- No previous run is still up: `ls .rig/env` fails, or the operator confirms the previous
  rig was torn down.

## Commands

```
make CLOUD=$CLOUD preflight
```

Stop here. Print the resources the plan will create (3 Kafka broker VMs with local NVMe,
1 driver VM, static addresses, a dedicated VPC with NAT, a 3-node Kubernetes cluster, firewall
rules or security groups) and the hourly cost estimate the `infra-up` target prints before it
applies. Wait for an explicit "yes".

```
make CLOUD=$CLOUD infra-up
make CLOUD=$CLOUD addons-up
make CLOUD=$CLOUD env
make CLOUD=$CLOUD status
cat .rig/env
```

`infra-up` runs the `infra` Terraform root (network, Kafka, Kubernetes cluster) and waits for
the Kafka controller quorum to report three brokers. `addons-up` runs the `k8s-addons` root
(namespace, license Secret, management TLS Secret). `env` writes `.rig/env` from both roots'
outputs. `status` asserts the Kafka rig is complete: a KRaft leader, 3 brokers answering on
the internal listener, and the external listener reachable from this machine.

## Expected green output

- `infra-up` ends with Terraform's `Apply complete!` line and the quorum gate printing three
  broker ids.
- `addons-up` ends with `Apply complete!`.
- `.rig/env` contains all of: `CLOUD`, `KAFKA_BOOTSTRAP_EXTERNAL`, `KAFKA_BOOTSTRAP_INTERNAL`,
  `DRIVER_SSH`, `DRIVER_IP`, `KUBECONFIG_CMD`, `CLUSTER_NAME`, `KUBEMQ_NAMESPACE`,
  `STORAGE_CLASS`, `LICENSE_SECRET`, `TLS_SECRET`, `HOURLY_COST`. None is empty.
- `status` exits 0 and ends with the line `KAFKA RIG OK` (its data section says "not seeded
  yet" until prompt 02).

## Expected duration

GCP: 15–25 minutes. AWS: 25–35 minutes (the EKS control plane alone takes 10–15 minutes).

## Gate

`.rig/env` exists with every key non-empty and `make CLOUD=$CLOUD status` exits 0. Otherwise
stop, quote the failing line, and do **not** continue to prompt 02. Resources are now billing
at `HOURLY_COST`; say so in your final message.

## What this proves and does not prove

Proves: the operator's account, quotas and credentials can hold the full fixture, and the
Kafka cluster formed a controller quorum.

Does not prove: that Kafka holds any data (that is prompt 02), that the Kubernetes cluster can
pull images or bind volumes (that is prompt 03), or anything about KubeMQ.
