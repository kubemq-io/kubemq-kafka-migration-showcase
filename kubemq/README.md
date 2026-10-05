# KubeMQ install input for `kmq deploy`

This directory holds the recipe files that `kmq deploy prepare --input` reads. One file per
cloud; the two differ only in `kubernetes.storage_class`.

Every claim below was checked against the kmq source at the pinned version. "Source" lines
name the Go file inside the kmq command-line tool's source tree (the `cli/` tree of the KubeMQ
server repository) so a reviewer with access can confirm them.

## How the file is used

`kmq deploy` installs KubeMQ in three steps. Each step reads the output of the previous one.

```
kmq deploy prepare --input .rig/deploy-input.json --out .rig/recipe.json
kmq deploy plan    --input .rig/recipe.json       --out .rig/plan.json
kmq deploy apply   --plan  .rig/plan.json
```

- `prepare` validates the shape, downloads the pinned Helm chart, resolves the server and
  operator images to digests, creates the namespace if missing, verifies the license and TLS
  Secrets you named, and writes a completed recipe. Source: `cli/internal/deployment/prepare.go`
  (function `Prepare`), `cli/cmd/onboarding_deploy.go` (the `prepare` subcommand, `--input`,
  `--out`).
- `plan` inspects the cluster and saves an immutable plan with an `installation_id`.
  Source: `cli/cmd/onboarding_deploy.go` (the `plan` subcommand; `--out` is required).
- `apply` takes `--plan PATH` (or `--installation ID` to resume). It does **not** take
  `--input`. Source: `cli/cmd/onboarding_deploy.go` (the `apply` subcommand).

The files in this directory are templates. Prompt 03 copies one to `.rig/deploy-input.json`
and replaces the `__PLACEHOLDER__` values before running `prepare`. `.rig/` is git-ignored.

## Field by field

The schema is the Go type `deployment.Input` in `cli/internal/deployment/types.go`. The decoder
rejects unknown fields, so do not add keys.

| Field | Value here | Why | Source |
|---|---|---|---|
| `schema_version` | `1` | Only version 1 is read. | `types.go`, `Input.Validate` |
| `goal` | `evaluation` | One of `evaluation`, `trial`, `production`. With a named license Secret no saved kmq license reference is needed. | `types.go`, `Input.Validate`; `prepare.go` (license branch is skipped when `license_secret.name` is set) |
| `target` | `kubernetes` | Selects the Kubernetes adapter. | `types.go` |
| `name` | `kubemq` | Installation resource name. Becomes the Helm `fullnameOverride`, the KubemqCluster name, the StatefulSet pod prefix (`kubemq-0`, `kubemq-1`, `kubemq-2`) and the admin Secret prefix (`kubemq-api-admin`). | `cli/internal/deployment/kubernetes.go` (`clusterValues`), `cli/internal/deployment/bootstrap.go` (admin Secret name) |
| `image` | `__KMQ_DEFAULT_SERVER_IMAGE__` | **Required and must be fully qualified with a tag** (`REGISTRY/REPOSITORY:TAG`, not `latest`); an empty value is refused. When `--input` is used kmq does not fill in its built-in default, so the prompt copies the default shown by `kmq deploy prepare --help` for the `--image` flag. `prepare` resolves the tag to a digest. | `cli/internal/deployment/artifacts.go` (`resolvePublicImage`); `cli/cmd/onboarding_deploy.go` (`--image` flag default) |
| `kubernetes.context` | `__KUBE_CONTEXT__` | Required; the kubeconfig context name. Filled from `kubectl config current-context` after the kubeconfig command from `.rig/env`. | `prepare.go` (refuses an empty context) |
| `kubernetes.namespace` | `kubemq` | Created by `prepare` if missing. The Terraform addons root also creates it (idempotent). | `prepare.go` |
| `kubernetes.chart` | `""` | Empty means `prepare` downloads the chart version pinned inside this kmq release. | `prepare.go` |
| `kubernetes.chart_version` | `""` | Empty means the pin inside this kmq release. | `prepare.go` |
| `kubernetes.operator_release` | `kubemq-operator` | Helm release name of the operator. Must differ from `cluster_release`. | `types.go`, `validateKubernetes` |
| `kubernetes.operator_image` | `""` | Empty means the pin inside this kmq release. | `prepare.go` |
| `kubernetes.cluster_release` | `kubemq` | Helm release name of the cluster. | `types.go` |
| `kubernetes.server_count` | `3` | Must be odd and at least 3. | `types.go`, `validateShape` |
| `kubernetes.storage_class` | `standard-rwo` (GCP) / `gp3` (AWS) | Required; an empty value is refused. Becomes Helm value `volume.storageClass`. | `types.go`, `validateShape`; `kubernetes.go` (`clusterValues`) |
| `kubernetes.volume_size` | `50Gi` | Required. Becomes Helm value `volume.size` (one volume per server). | `types.go`; `kubernetes.go` |
| `kubernetes.license_secret.name` | `__LICENSE_SECRET__` | Existing Secret in the namespace, created by Terraform. Filled from `LICENSE_SECRET` in `.rig/env`. When set, `prepare` does not need a saved kmq license reference. **Alternative:** delete the whole `license_secret` object and set top-level `"credential": "license-<ref>"` from `kmq license list` (a key imported with `kmq license import` or claimed with `kmq trial claim`); `prepare` then creates the Secret itself (`<name>-license-<digest>`, key `license`). The first run of this repository used that path. | `prepare.go` (license branch); `types.go` |
| `kubernetes.license_secret.key` | `licenseKey` | Data key inside that Secret. Must match the key Terraform writes. | `types.go`, `validateKubernetes`; `kubernetes.go` passes `name` and `key` to the chart's `licenseKeySecretRef` |
| `kubernetes.license_secret.kind` | `key` | `key` for an online activation key (chart value `licenseKeySecretRef`), `file` for an offline signed license file (`licenseFileSecretRef`). | `kubernetes.go` (`clusterValues`) |
| `kubernetes.tls_secret` | `__TLS_SECRET__` | Existing `kubernetes.io/tls` Secret for the management API. Filled from `TLS_SECRET` in `.rig/env`. Becomes Helm value `api.tlsSecret`. | `types.go`; `kubernetes.go` |
| `kubernetes.ca_file` | `__CA_FILE__` | **Required whenever `tls_secret` is set.** Local PEM file kmq trusts when it dials the management API. For a self-signed certificate this is the certificate itself (`tls.crt`); the prompt extracts it to `.rig/management-ca.pem`. | `types.go`, `validateKubernetes` |

Alternative for TLS: leave `tls_secret` and `ca_file` **both empty**. `prepare` then generates a
certificate whose names cover the api Service and every per-pod name the migration worker dials,
creates the Secret `<name>-management-tls`, and writes the CA file into its private directory.
Source: `prepare.go` (`managementTLSHosts`). If you use the Terraform certificate instead, its
Subject Alternative Names must cover the same list: `kubemq-api.kubemq.svc`,
`kubemq-api.kubemq.svc.cluster.local`, `*.kubemq.kubemq.svc`, `*.kubemq.kubemq.svc.cluster.local`,
`localhost`, `127.0.0.1`, and `kubemq-N.kubemq.kubemq.svc.cluster.local` for N = 0, 1, 2.

## Settings you cannot put in this file (kmq sets them itself)

`kmq deploy apply` renders the chart with a fixed set of values. These are not fields of the
input file; they are always applied. Source: `cli/internal/deployment/kubernetes.go`, function
`clusterValues`.

- `store.engine: next` — the storage engine the Kafka listener requires.
- `env.STORE_NEXT_ACK_POLICY: strict` — strict disk acknowledgement. This is the setting the
  migration's probe and target-check later read back from each server. It cannot be turned off
  through the recipe.
- `api.tlsSecret: <tls_secret>` and `api.auth.enable: true` — authenticated management API over TLS.
- `health.enabled: true`.
- `replicas`, `image`, `volume.size`, `volume.storageClass`, the license Secret reference, and
  `operator.enabled: false` for the cluster release.

Kafka listener: the recipe has no Kafka field. The operator turns the Kafka listener **on by
default** whenever the store engine is `next` and `spec.kafka.enabled` is not set to `false`.
The listener is plaintext unless a Kafka user Secret or data-plane authentication is configured,
and `kmq deploy` configures neither. Source: `cli/cmd/migrate_job_bootstrap.go` (the comment on
`kafkaDefaultOn`, function `targetAddressing`, and function `targetListenerRequiresSASL`).

Management endpoints: when `kubernetes.management_endpoints` is omitted, `prepare` records
`https://127.0.0.1:18080`, `:18081`, `:18082` — one loopback tunnel per server, opened later by
`kmq deploy forward --installation <id> --all`. Source: `prepare.go` (end of `Prepare`).

## Admin credentials after install

The operator seeds an administrator account. kmq reads the seeded password from Secret
`<name>-api-admin` (here `kubemq-api-admin`), data key `admin-password`, and only when that
Secret is owned by the KubemqCluster kmq installed. Source: `cli/internal/deployment/bootstrap.go`
(`BootstrapPassword`). The server's default administrator username is `admin` (environment
`KUBEMQ_API_ADMIN_USERNAME` changes it; `kmq deploy` does not set it).

## What `kmq deploy` does not do here

- It does not create the license or TLS Secrets you name; Terraform does.
- It does not expose anything outside the cluster. The Kafka listener and the management API
  are reached from inside the cluster (migration worker Jobs) or over loopback tunnels.
- It does not uninstall on its own. `kmq deploy remove --installation <id>` removes the runtime
  and retains data; the teardown script handles the rest. Source: `cli/cmd/onboarding_deploy.go`
  (`status`, `restart`, `remove` subcommands).
