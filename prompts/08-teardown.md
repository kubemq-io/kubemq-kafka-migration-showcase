# 08 — Teardown

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

- `.rig/env` (`CLOUD`, `HOURLY_COST`), `.rig/kmq.env` (`INSTALLATION_ID`).

## Preconditions

- `migration/report.json` has been retrieved and copied somewhere safe if you want to keep it.
  Teardown deletes the state volume that holds the checkpoint and the report.
- The operator has said "yes" to tearing down. Teardown is irreversible: the Kafka brokers'
  local NVMe data and all KubeMQ volumes are destroyed.

## Commands

```
set -a; . .rig/env; . .rig/kmq.env; set +a
eval "$KUBECONFIG_CMD"
kill "$(cat .rig/forward.pid 2>/dev/null)" 2>/dev/null || true
kubectl -n "$KUBEMQ_NAMESPACE" delete pod kmq-report-reader --ignore-not-found
make CLOUD=$CLOUD down
make CLOUD=$CLOUD verify-teardown
```

`down` runs three things in order. First `scripts/pre-destroy.sh`, which removes what
Terraform cannot see: it runs `kmq deploy remove --installation $INSTALLATION_ID` when
`.rig/kmq.env` exists (best effort), deletes the KubemqCluster (the chart keeps it on
uninstall by design), every PersistentVolumeClaim in the namespace (KubeMQ data volumes and
the migration state volume) and any `LoadBalancer` Service, then waits for the backing
PersistentVolumes to disappear. Second, `terraform destroy` in the `k8s-addons` root, then in
the `infra` root. Third, `scripts/verify-teardown.sh`, which re-queries the cloud by the
showcase label **and** by the Kubernetes-owned tags for VMs, disks, firewall rules or security
groups, forwarding rules or load balancers, static or elastic IPs and NAT gateways, and exits
non-zero listing anything that still exists.

Do not run `make pre-destroy` separately before `down`: `down` already runs it, and a second
pass warns `kmq deploy remove returned non-zero (record already removed?)`, which is noise.
Keep the `set -a; . .rig/env` line above: `down` deletes `.rig/env` after its own verification
step, so the separate `make verify-teardown` that follows relies on the exported `CLUSTER_NAME`
to match the Kubernetes-owned disks and load balancers.

If `down` fails part-way, re-run `make CLOUD=$CLOUD down`; Terraform resumes. If
`verify-teardown` lists leftovers, delete them with the cloud CLI as the output suggests
(`docs/08-teardown-and-cost.md`), then re-run `verify-teardown` until it is clean.

## Expected green output

- the pre-destroy part of `down` → `kmq deploy remove` prints a state with
  `"data_retained": true` (the volumes are then deleted by the PVC step), the KubemqCluster,
  PVCs and LoadBalancer Services are listed as deleted (or `none`), and
  `no PersistentVolumes remain`.
- `down` → two `Destroy complete!` lines.
- `verify-teardown` → the literal line `TEARDOWN VERIFIED CLEAN`.

## Expected duration

10–20 minutes. Kubernetes cluster deletion dominates (GKE 5–8 min, EKS 10–15 min).

## Gate

The literal line `TEARDOWN VERIFIED CLEAN` was printed. Nothing else counts. Your final message
must then say: "No showcase resources are running; hourly cost is now 0." If the line was not
printed, your final message must list what `verify-teardown` reported and state that those
resources are still billing.

Afterwards, optionally remove local state: `rm -rf .rig migration/plan.json`. Keep
`migration/report.json` if you want to compare it with the reference report later.

## What this proves and does not prove

Proves: nothing this repository created, by its own label or by the Kubernetes cluster's
tags, still exists in the account.

Does not prove: that resources created outside this repository (for example a manually added
budget alert or a disk you attached by hand) are gone; it only queries what the showcase
labelled or what Kubernetes tagged with this cluster's name.
