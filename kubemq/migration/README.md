# Migration declaration

`declaration.example.json` is the operator-authored input of `kmq migrate plan`. In this
showcase you never author it from scratch: `kmq migrate job bootstrap` writes a pre-filled
`migration/declaration.json`, and you edit that file so it matches the example here (10 topics,
3 consumer groups, one placeholder application). The plan is then created inside the cluster
with `kmq migrate job tool --tool plan`.

Every statement below was checked against the kmq source at the pinned version. "Source"
lines name files in the kmq command-line tool's source tree (the `cli/` tree of the KubeMQ
server repository).

## Where the file comes from and where it goes

1. `kmq migrate plan --print-template` prints a complete example declaration with every field.
   Source: `cli/cmd/migrate_plan.go`, function `migrationPlanTemplate` and flag `--print-template`.
2. `kmq migrate job bootstrap ... --out ./migration` writes `migration/declaration.json`: the
   same template with every field the installation determines already filled in — both profile
   names, and all seven `target.*` pins. It never overwrites an existing `declaration.json`.
   Source: `cli/cmd/migrate_job_bootstrap.go`, function `bootstrapDeclaration` and the `RunE`
   of the `bootstrap` command.
3. You edit `topics`, `groups`, `workload.applications`, `workload.source_writers`,
   `workload.semantics.*` and the volume numbers.
4. `kmq migrate job tool --bootstrap-file migration/bootstrap.json --tool plan --input
   migration/declaration.json --output migration/plan.json` runs `kmq migrate plan --dry-run`
   inside the cluster and saves the printed plan. Source: `cli/cmd/migrate_job_tool.go`,
   function `toolArguments` (case `plan`).

The decoder refuses unknown fields and files over one megabyte. Source: `cli/cmd/migrate_plan.go`,
function `readPlanRequest`.

Validation reports **every** problem in one run, in the error's `details` list, so fix the
declaration in one edit. Source: `cli/internal/kafkamigrate/plan.go`, function
`ValidatePlanRequest`; `cli/cmd/migrate_plan.go`, function `planRequestExitError`.

## Field by field

Schema: Go type `kafkamigrate.PlanRequest` in `cli/internal/kafkamigrate/plan.go`. Validation
rules: `ValidatePlanRequest` in the same file unless noted.

| Field | In this showcase | Rule |
|---|---|---|
| `source_profile` | filled by bootstrap: `<your source profile>-worker` | Required, must differ from `target_profile`. The bootstrap saves a worker copy of your source profile under this name. Source: `migrate_job_bootstrap.go`, function `run` (`SourceProfile: opts.SourceProfile + "-worker"`). |
| `target_profile` | filled by bootstrap: `<cluster name>-target` | Required. The bootstrap derives a plaintext profile pointing at the three in-cluster pod addresses on port 9092. Source: `migrate_job_bootstrap.go`, `run` and `targetAddressing`. |
| `source_profile_hash`, `target_profile_hash` | `""` | Leave empty. The plan command fills each from the saved profile's fingerprint; a non-empty value is only a pin that must match. Source: `migrate_plan.go`, the fingerprint loop in `RunE`. |
| `target_management_context` | omitted | Bootstrap sets it empty; the worker authenticates to the management API with the read-only key the bootstrap minted into the credential Secret. Source: `bootstrapDeclaration`. |
| `worker_kmq_version` | omitted | Filled with the authoring kmq version. A declared value that names another kmq is refused. Source: `migrate_plan.go`, `applyWorkerImageAndVersion`. |
| `topics` | the 10 seeded topics | At least one; no empty, padded or repeated names. Every topic must exist on the source with the same partition count on the target, and target partitions must be empty. Source: `plan.go` (`uniqueNames`, `Plan.Validate`); `migrate_plan.go` (`requireEmptyMigrationTarget`). |
| `groups` | `analytics`, `billing`, `archiver` | At least one, unique. The plan records them; this showcase never seeds their offsets on the target. |
| `target.kubernetes_context` | filled by bootstrap | `job submit` refuses a plan whose context or namespace differ from the bootstrap's. Source: `cli/cmd/migrate_job.go`, function `submit`. |
| `target.namespace`, `target.release` | filled by bootstrap (`kubemq`, `kubemq`) | Non-empty. |
| `target.worker_image` | filled by bootstrap: the published kmq worker image **by digest** | The bootstrap resolves the tag of this kmq release to a digest when the registry is reachable. The plan refuses an image whose tag does not match the running kmq. Source: `migrate_job_bootstrap.go` (`pinWorkerImage`); `migrate_plan.go` (`checkWorkerImageTag`). |
| `target.server_image`, `target.operator_image`, `target.chart_version` | filled by bootstrap from the installation record | Non-empty pins. They are the values `kmq deploy prepare` resolved; do not type them by hand. |
| `workload.applications` | one placeholder, `showcase-consumer` at `git:0000000` | **Must be non-empty**, names unique, revisions non-empty. The showcase has no real application; the placeholder documents that. Source: `ValidatePlanRequest`. |
| `workload.applications[].smoke_probe` | omitted | Optional. With three planned groups a probe would need an explicit `group`; omitting the probe avoids that. Source: `ValidatePlanRequest`, `ApplyPlanRequestDefaults`. |
| `workload.source_writers` | `["showcase-seeder"]` | At least one unique name is required (`migration plan requires at least one source writer`). The showcase names the seeder; nothing writes to the source during the copy. |
| `workload.source_handoff_window_seconds` | omitted (0) | 0 to 3600; 0 means the 30-second default. Only used by cutover stages, which this showcase does not run. |
| `workload.offset_authority` | `kafka-consumer-groups` | The only accepted value. Source: `ValidatePlanRequest`. |
| `workload.semantics.schema_registry` / `streams_state` / `transactions` | `status: none` with evidence | Each `status` must be exactly `none` for the ordinary-topic path; `unknown` or missing is refused; any other value needs a separately qualified path. `evidence_source` is required, at most 512 characters, single line. `observed_at` must be a real time. `inspected_scope` must be non-empty and must include every planned application name; an empty list is refused, never read as "everything". Source: `ValidatePlanRequest`. |
| `workload.data_bytes` | `536870912` (512 MiB) | Non-negative estimate. Prompt 05 overwrites it with `RECORDS × 1024` from `.rig/seed.env` (512,000,000 for the default seed, 5,120,000,000 for the 5,000,000-record run). The seeder's `-size` flag sets the value size. |
| `workload.write_bytes_per_second` | `0` | Non-negative. Nothing writes to the source during the showcase. |
| `workload.max_write_pause_seconds` | `600` | **Must be positive** even though no pause happens here. Source: `ValidatePlanRequest`. |
| `workload.recovery_policy` | free text | Non-empty. |

## Why the example carries `__FILLED_BY_BOOTSTRAP__` placeholders

The seven `target.*` pins and the two profile names depend on your installation record (the
kubeconfig context name, the image digests the installer resolved, the chart version inside this
kmq release). Typing them by hand invites a mismatch that `job submit` or `job tool` would refuse.
Let the bootstrap write them, then copy only the `topics`, `groups` and `workload` blocks from
this example into `migration/declaration.json`.

A simple way to merge (requires `jq`):

```
jq -s '.[0] * {topics: .[1].topics, groups: .[1].groups, workload: .[1].workload}' \
  migration/declaration.json kubemq/migration/declaration.example.json > migration/declaration.tmp \
  && mv migration/declaration.tmp migration/declaration.json
```

## What the declaration is not

- It carries no credentials. Profiles hold addresses and credential references; the worker's
  Kafka credentials and management key live in the Kubernetes Secret the bootstrap created.
  Source: `cli/cmd/migrate_plan.go` (`Long` description; refusal of literal credentials).
- It is not the plan. The plan adds the source and target cluster identities, a run id and a
  hash, and is immutable; an existing plan file is never overwritten. Source:
  `cli/internal/kafkamigrate/plan.go`, `NewPlan` and `SavePlan`.
- A passing plan does not certify data, applications or a cutover. It certifies that the
  declared scope exists on both sides with matching partition layout and an empty target.
