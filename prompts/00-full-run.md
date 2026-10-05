# 00 — Full run (orchestrator)

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

## What this prompt is

This prompt does no work of its own. It runs prompts 01 through 08 **in order**, one at a
time, and stops at every gate. Each step prompt is self-contained; this file only sequences
them. If your agent cannot keep a session alive for 60 to 90 minutes, do not use this prompt —
paste the step prompts one by one instead.

## Inputs

- `CLOUD` — `gcp` or `aws`, given by the operator now. Write it down; every `make` call uses
  `CLOUD=$CLOUD`.
- Everything else is read from `.rig/env`, `.rig/seed.env` and `.rig/kmq.env` as each step
  writes them.

## Preconditions

- `make CLOUD=$CLOUD preflight` exits 0. If it does not, stop and report its output; the
  fixes are printed by the preflight itself (see `docs/00-prerequisites.md`).
- The operator has a KubeMQ license that permits at least 3 Kubernetes servers, and has set
  the Terraform variables described in `docs/02-gcp-walkthrough.md` or
  `docs/03-aws-walkthrough.md`.

## Commands

For each step, open the named prompt file, inline-read it fully, and execute it exactly:

1. `prompts/01-infra-up.md` — creates billing resources; the cost gate applies here.
2. After step 1, re-read `.rig/env`. Then `prompts/02-seed-kafka.md`.
3. After step 2, re-read `.rig/seed.env`. Then `prompts/03-install-kmq-and-kubemq.md`.
4. After step 3, re-read `.rig/kmq.env`. Then `prompts/04-migrate-bootstrap-and-probe.md`.
5. `prompts/05-migrate-plan.md`.
6. `prompts/06-migrate-replicate.md`.
7. `prompts/07-migrate-verify-and-report.md`.
8. Ask the operator: "Tear down now? (yes/no)". On yes, `prompts/08-teardown.md`. On no, end
   the session with the final message required by rule 4, stating the hourly cost that keeps
   accruing.

Between steps, do not carry values forward from memory; re-read the `.rig/*` files.

## Expected green output

Each step prompt names its own green output. The orchestrator's green output is: every gate
passed, `migration/report.json` exists, and — if teardown was requested — the literal line
`TEARDOWN VERIFIED CLEAN` appeared.

## Expected duration

| Step | Default seed (500,000 records) |
|---|---|
| 01 infra | 15–35 min (GCP 15–25, AWS 25–35; the EKS control plane is the slow part) |
| 02 seed | 3–8 min |
| 03 install | 10–20 min |
| 04 bootstrap + probe | 5–10 min |
| 05 plan | 2–5 min |
| 06 replicate | 5–15 min at the default seed (observed: about 1 min wall clock, 20 s of worker time, for 500,000 records on GCP); the 5,000,000-record run took about 1,108 s of worker copy time on a different fixture; neither is a guarantee |
| 07 verify + report | 3–10 min |
| 08 teardown | 10–20 min |

## Gate

The run is complete only when `migration/report.json` has been retrieved **and** the operator
has been told, in the final message, whether resources are still running and at what hourly
cost. A session that ends without that sentence has not finished.

## What this proves and does not prove

Proves: an operator with their own cloud account and license can reproduce bulk copy, full
verification and a report from a real 3-broker Apache Kafka cluster into a 3-server KubeMQ
cluster using only public tooling.

Does not prove: consumer-group offset seeding on the target, application cutover, writer
pause, recovery after a worker interruption (referenced, not exercised), production
capacity, or anything about Amazon MSK or Confluent Cloud.
