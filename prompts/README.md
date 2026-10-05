# Agent prompts

These are plain-markdown prompts for a coding agent (Claude Code, Cursor, GitHub Copilot,
Codex). Paste one prompt into a fresh agent session, in order. Each prompt is self-contained:
it tells the agent what to read, what to run, what green looks like, how long it should take,
and the gate that must pass before the next prompt.

## The contract every prompt follows

- Every prompt **starts with the content of `_header.md`**, inlined. Those seven rules are
  the safety contract: cost gate before creating resources, red output is failure, only the
  literal `TEARDOWN VERIFIED CLEAN` means nothing bills, the final message states cost, verify
  is not cutover, never invent `kmq` flags, read state from `.rig/*` files.
- Every prompt has the same sections: **Inputs**, **Preconditions**, **Commands**,
  **Expected green output**, **Expected duration**, **Gate**.
- Every prompt is idempotent. Re-running it after a failure is safe; the commands either skip
  what already exists or refuse with a clear message.
- Infrastructure, seeding and teardown go through `make CLOUD=gcp ...` or `make CLOUD=aws ...`
  targets. KubeMQ install and migration go through `kmq` commands exactly as written in the
  prompt; every one of them was verified against the kmq source at the pinned version.
- Each prompt says what the step **proves** and what it **does not prove**.

## Order

| Prompt | What it does | Creates billing resources? |
|---|---|---|
| `00-full-run.md` | Orchestrator: runs 01 → 08 in order, stops at every gate | via 01 |
| `01-infra-up.md` | Terraform: network, Kafka VMs, Kubernetes cluster, Secrets; writes `.rig/env` | **yes** |
| `02-seed-kafka.md` | Seeds 10 topics, 60 partitions, 3 consumer groups | no (uses existing) |
| `03-install-kmq-and-kubemq.md` | Installs kmq, installs KubeMQ with `kmq deploy`, logs in | no (uses existing) |
| `04-migrate-bootstrap-and-probe.md` | Source profile, read-only assess, worker bootstrap, in-cluster probe and target-check | small PVC |
| `05-migrate-plan.md` | Edits the declaration, creates the immutable plan in-cluster | no |
| `06-migrate-replicate.md` | Runs the replicate Job, polls status | no |
| `07-migrate-verify-and-report.md` | Runs verify and report Jobs, retrieves `report.json` | no |
| `08-teardown.md` | Pre-destroy cleanup, Terraform destroy, teardown verification | **removes** |

Set `CLOUD=gcp` or `CLOUD=aws` in `.rig/env` (prompt 01 writes it) before anything else.

## Per-agent portability notes

- **Claude Code**: use as-is. Long-running commands (Terraform apply, the replicate Job) fit
  inside one turn; the agent polls `kmq migrate job status` in a loop.
- **Cursor (Agent mode)**: needs the integrated terminal enabled for the agent. Same prompts.
- **GitHub Copilot (agent/chat)**: cannot long-poll a shell command for 20+ minutes. Run the
  prompt; when it stops at a waiting loop, re-run the same prompt — every prompt is idempotent
  and prompt 07 in particular is written to be re-run to check status.
- **Codex**: needs the network-enabled sandbox (cloud APIs, Helm chart download, container
  registry lookups). Without it, `kmq deploy prepare` and `kmq migrate job bootstrap` fail with
  connection errors, not with wrong results.
- **macOS**: the scripts need bash 4 or newer (`brew install bash`) and `curl -4`. The
  preflight target checks this.
- **Windows**: not supported by the Makefile and scripts. Use WSL2.

## Files the prompts read and write

- `.rig/env` — written by `make CLOUD=$CLOUD env` from Terraform outputs. Keys: `CLOUD`,
  `KAFKA_BOOTSTRAP_EXTERNAL`, `KAFKA_BOOTSTRAP_INTERNAL`, `DRIVER_SSH`, `DRIVER_IP`,
  `KUBECONFIG_CMD`, `CLUSTER_NAME`, `KUBEMQ_NAMESPACE`, `STORAGE_CLASS`, `LICENSE_SECRET`,
  `TLS_SECRET`, `HOURLY_COST`.
- `.rig/seed.env` — written by `make seed`. Keys: `RECORDS`, `TOPICS`, `PARTITIONS`, `SIZE`,
  `SEEDED_AT`.
- `.rig/kmq.env` — written by prompt 03. Keys: `INSTALLATION_ID`, `ADMIN_USERNAME`,
  `CLUSTER_RELEASE`. The source Kafka profile prompt 04 creates is always named `kafka-src`.
- `.rig/admin-password` — the new administrator password prompt 03 generates and sets (it
  replaces the operator-seeded one-time password), mode 0600.
- `migration/` — `declaration.json`, `bootstrap.json`, `probe.json`, `target-check.json`,
  `prepare-request.json`, `prepare-plan.json`, `prepare-result.json`, `plan.json`, `report.json`.

`.rig/`, `migration/plan.json` and `migration/bootstrap.json` are git-ignored. Never commit them.
