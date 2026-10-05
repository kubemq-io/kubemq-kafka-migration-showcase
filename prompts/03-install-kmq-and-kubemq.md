# 03 — Install kmq and KubeMQ

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

- `.rig/env`: `CLOUD`, `KUBECONFIG_CMD`, `KUBEMQ_NAMESPACE`, `STORAGE_CLASS`,
  `LICENSE_SECRET`, `TLS_SECRET`, `HOURLY_COST`.
- `versions.env`: `KMQ_VERSION` (the exact kmq release this repository is pinned to).
- `kubemq/deploy-input.$CLOUD.json`: the install recipe template (see `kubemq/README.md`).

## Preconditions

- Prompt 01 passed: `make CLOUD=$CLOUD status` exits 0.
- `jq`, `kubectl` and `helm` are on PATH (`kmq deploy prepare` calls helm and kubectl).
- Nothing else is installed in namespace `$KUBEMQ_NAMESPACE` besides the two Secrets Terraform
  created. `kmq deploy prepare` refuses to install over a foreign Helm release.

## Commands

### 1. Install kmq at the pinned version and load its guide

```
set -a; . .rig/env; . versions.env; set +a
scripts/kmq-install.sh                       # wraps the public installer with --version $KMQ_VERSION; refuses a mismatch
kmq version
kmq skills get core
kmq deploy prepare --help
kmq deploy plan --help
kmq deploy apply --help
kmq deploy status --help
kmq deploy forward --help
kmq auth login --help
kmq migrate plan --help
```

`kmq version` must print `"version": "<KMQ_VERSION>"`. If it prints another version, stop:
the migration worker image is pinned to the kmq version and `job submit` refuses a mismatch.

### 2. Point kubectl at the new cluster and fill the recipe placeholders

```
eval "$KUBECONFIG_CMD"
KUBE_CONTEXT=$(kubectl config current-context)
kubectl get storageclass "$STORAGE_CLASS"
kubectl -n "$KUBEMQ_NAMESPACE" get secret "$LICENSE_SECRET" "$TLS_SECRET"

# The default server image of THIS kmq release, read from its own --help text.
SERVER_IMAGE=$(kmq deploy prepare --help | sed -n 's/.*--image string.*(default "\([^"]*\)").*/\1/p')
test -n "$SERVER_IMAGE"

# The trust anchor for the management certificate Terraform created.
mkdir -p .rig
if kubectl -n "$KUBEMQ_NAMESPACE" get secret "$TLS_SECRET" -o jsonpath='{.data.ca\.crt}' | grep -q .; then
  kubectl -n "$KUBEMQ_NAMESPACE" get secret "$TLS_SECRET" -o jsonpath='{.data.ca\.crt}'  | base64 -d > .rig/management-ca.pem
else
  kubectl -n "$KUBEMQ_NAMESPACE" get secret "$TLS_SECRET" -o jsonpath='{.data.tls\.crt}' | base64 -d > .rig/management-ca.pem
fi

jq --arg img "$SERVER_IMAGE" --arg ctx "$KUBE_CONTEXT" --arg ns "$KUBEMQ_NAMESPACE" \
   --arg sc "$STORAGE_CLASS" --arg lic "$LICENSE_SECRET" --arg tls "$TLS_SECRET" \
   --arg ca "$PWD/.rig/management-ca.pem" \
   '.image=$img | .kubernetes.context=$ctx | .kubernetes.namespace=$ns
    | .kubernetes.storage_class=$sc | .kubernetes.license_secret.name=$lic
    | .kubernetes.tls_secret=$tls | .kubernetes.ca_file=$ca' \
   "kubemq/deploy-input.$CLOUD.json" > .rig/deploy-input.json
grep -c '__' .rig/deploy-input.json || true   # must print 0: no placeholder left
```

If Terraform did not create a license Secret (`LICENSE_SECRET` empty in `.rig/env`) because
the key is stored in kmq instead, use the saved credential: `kmq license list` shows its
`reference`; then replace the `license_secret` object with a top-level `credential`:

```
CRED=$(kmq license list | jq -r '.[0].reference')   # pick the right one if several
jq --arg c "$CRED" '.credential=$c | del(.kubernetes.license_secret)' .rig/deploy-input.json > .rig/deploy-input.tmp && mv .rig/deploy-input.tmp .rig/deploy-input.json
```

Otherwise the license Secret's data key must be `licenseKey` (what the recipe names). Check:
`kubectl -n "$KUBEMQ_NAMESPACE" get secret "$LICENSE_SECRET" -o jsonpath='{.data.licenseKey}' | grep -q .`

### 3. Prepare, plan, apply

```
kmq deploy prepare --input .rig/deploy-input.json --out .rig/recipe.json
kmq deploy plan    --input .rig/recipe.json       --out .rig/plan.json
INSTALLATION_ID=$(jq -r .installation_id .rig/plan.json)
kmq deploy apply   --plan .rig/plan.json
```

`prepare` downloads the chart pinned in this kmq, resolves both images to digests, checks the
node architectures can pull them, verifies the two Secrets, and records three loopback
management endpoints. `plan` writes an immutable plan with the `installation_id` that every
later command uses. `apply` installs the operator release and the cluster release with the
values kmq fixes itself (strict disk acknowledgement, authenticated TLS management API, next
storage engine, 3 replicas, your storage class and 50Gi volumes). `apply` takes `--plan`, not
`--input`.

If `prepare` or `plan` fails with `invalid_deployment_input`, the message names the exact
field; fix `.rig/deploy-input.json` and re-run. Do not edit `.rig/recipe.json` or
`.rig/plan.json` by hand: a plan whose content hash no longer matches is refused.

### 4. Wait for three servers

```
for i in 0 1 2; do
  until kubectl -n "$KUBEMQ_NAMESPACE" get pod "kubemq-$i" >/dev/null 2>&1; do sleep 10; done
done
kubectl -n "$KUBEMQ_NAMESPACE" wait --for=condition=Ready pod/kubemq-0 pod/kubemq-1 pod/kubemq-2 --timeout=20m
until kmq deploy status --installation "$INSTALLATION_ID" | tee /dev/stderr | grep -q '"state": *"cluster_ready'; do sleep 20; done
```

The pods are named `<name>-0`, `<name>-1`, `<name>-2` after the recipe's `name` (`kubemq`).
`kmq deploy status` reports `cluster_ready_needs_authenticated_verification` once the
operator's `Ready` condition is true, all three servers are ready, the running image matches
the plan and a license id is recorded. While the cluster is forming it reports
`cluster_not_ready`; keep polling. If it stays there past 20 minutes, run
`kmq deploy diagnose --installation "$INSTALLATION_ID"` and quote its `failure_code`.

### 5. Choose a new administrator password

```
umask 077; mkdir -p .rig
openssl rand -base64 24 | tr -d '/+=' | cut -c1-28 > .rig/admin-password
chmod 600 .rig/admin-password
test -s .rig/admin-password
```

The operator seeds a one-time administrator password in Secret `<name>-api-admin` (key
`admin-password`). The first login must **replace** it: a service credential cannot be issued
while the seeded password is still in force (`password_change_required`). `kmq auth login
--bootstrap` reads the seeded password from the cluster Secret itself; you only supply the new
one. The username is `admin`. Never print either password. `.rig/` is git-ignored.

### 6. Open the management tunnels and log in

The management endpoints the plan recorded are `https://127.0.0.1:18080`, `:18081`, `:18082`
(one per server). They only exist while `kmq deploy forward` runs. Start it in the background
and keep it running for prompts 03 and 04:

```
nohup kmq deploy forward --installation "$INSTALLATION_ID" --all --duration 4h > .rig/forward.log 2>&1 &
echo $! > .rig/forward.pid
until [ "$(grep -c '"local_port"' .rig/forward.log)" -ge 3 ]; do sleep 2; done
```

Then log in once to every server, replacing the seeded password with yours, and save one
context per server (`--bootstrap` + `--new-password-stdin`; later logins use
`--password-stdin` with `.rig/admin-password`):

```
kmq auth login --installation "$INSTALLATION_ID" --all --bootstrap --username admin --new-password-stdin --non-interactive < .rig/admin-password
```

Optional but recommended — a real authenticated round trip through each server:

```
kmq deploy verify --installation "$INSTALLATION_ID"
```

### 7. Record installer state

```
cat > .rig/kmq.env <<EOF
INSTALLATION_ID=$INSTALLATION_ID
ADMIN_USERNAME=admin
CLUSTER_RELEASE=kubemq
EOF
```

## Expected green output

- `kmq version` → `{"version": "<KMQ_VERSION>", ...}`.
- `kmq deploy prepare` → `{"state": "prerequisites_prepared", "recipe": ".rig/recipe.json",
  "next_action": "deploy_plan_with_prepared_recipe"}`.
- `kmq deploy plan` → a JSON plan with a 32-hex-digit `installation_id` and `content_sha256`.
- `kmq deploy apply` → `"state"` other than a failure, `"data_retained": true`, and
  `"next_action": "run_deploy_status_until_cluster_ready_then_deploy_forward_all_then_auth_login_all_bootstrap_then_verify"`.
- `kubectl wait` → three `condition met` lines.
- `kmq deploy status` → `"state": "cluster_ready_needs_authenticated_verification"` (or
  `cluster_ready_verified` after `deploy verify`).
- `kmq deploy forward` log → three objects, each with `"local_port"` 18080, 18081, 18082.
- `kmq auth login --all` → `"state": "authenticated"` with three server entries.
- `kmq deploy verify` → `"state": "verified"`.

## Expected duration

10–20 minutes: chart and image resolution 1–2 min, operator and cluster install 1–2 min, pods
Ready 3–8 min (image pull plus volume bind), login under a minute.

## Gate

`.rig/kmq.env` exists, `kmq deploy status --installation "$INSTALLATION_ID"` reports a
`cluster_ready*` state, and `kmq auth login --all` reported `authenticated`. Otherwise stop,
quote the failing line, and do not continue. Resources are billing at `HOURLY_COST`.

## What this proves and does not prove

Proves: a 3-server KubeMQ cluster with strict disk acknowledgement and an authenticated TLS
management API runs in your Kubernetes cluster, installed by the same tool the migration uses,
and the installation record the migration bootstrap requires exists on this machine.

Does not prove: that the Kafka listener is reachable from the worker network, that the
servers report strict acknowledgement at run time, or anything about data. Prompt 04's
in-cluster probe and target-check do that.
