#!/usr/bin/env bash
#
# lib.sh — shared helpers for the laptop-side scripts. Sourced, never executed.
#
#   ROOT            repository root
#   RIG_DIR         $ROOT/.rig (gitignored run state: env, seed.env, kubeconfig, logs)
#   load_versions   source versions.env
#   load_rig_env    source .rig/env (fails if missing) and .rig/seed.env (optional)
#   driver_ssh CMD  run CMD on the driver VM via $DRIVER_SSH (plain ssh or gcloud compute ssh)
#   tf_bin          print the terraform binary to use ($TF, else terraform, else tofu)
#   say/warn/die    uniform output; die exits 1

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "FAIL: bash >= 4 required (macOS /bin/bash is 3.2; brew install bash)." >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RIG_DIR="$ROOT/.rig"
mkdir -p "$RIG_DIR"

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die()  { printf '⛔ %s\n' "$*" >&2; exit 1; }

load_versions() {
  # shellcheck disable=SC1091
  source "$ROOT/versions.env"
}

# load_rig_env [--without-seed]   (seed.sh passes the flag: seed.env would clobber its args)
load_rig_env() {
  [ -f "$RIG_DIR/env" ] || die "no $RIG_DIR/env — run 'make CLOUD=<gcp|aws> env' (or infra-up) first."
  # shellcheck disable=SC1091
  source "$RIG_DIR/env"
  if [ "${1:-}" != "--without-seed" ] && [ -f "$RIG_DIR/seed.env" ]; then
    # shellcheck disable=SC1091
    source "$RIG_DIR/seed.env"
  fi
}

# DRIVER_SSH is a full command, e.g.
#   ssh -i .rig/ssh_key -o StrictHostKeyChecking=no ubuntu@203.0.113.10
#   gcloud compute ssh kmq-showcase-driver --zone ZONE --project P
# Plain ssh takes the remote command as a positional argument; gcloud wants --command.
# stdin is passed through in both cases (seed.sh streams the binary over it).
# Host keys: the VMs are throwaway and a re-created driver reuses its static address, so
# host-key checking is disabled and nothing is written to known_hosts (BatchMode=yes
# would otherwise fail hard on the first, unknown, key). ssh honours the FIRST value of
# an option, so a DRIVER_SSH that already carries -o StrictHostKeyChecking wins.
driver_ssh() {
  [ -n "${DRIVER_SSH:-}" ] || die "DRIVER_SSH is empty in $RIG_DIR/env"
  local -a cmd
  read -r -a cmd <<<"$DRIVER_SSH"
  if [ "${cmd[0]}" = "gcloud" ]; then
    local -a extra=(--strict-host-key-checking=no)
    [[ " ${cmd[*]} " == *" --quiet "* ]] || extra+=(--quiet)
    "${cmd[@]}" "${extra[@]}" --command "$1"
  else
    "${cmd[@]}" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$1"
  fi
}

# Retry until the driver accepts SSH (a fresh VM refuses for 20-60s during cloud-init).
wait_driver_ssh() {
  local _i
  for _i in $(seq 1 30); do
    driver_ssh true >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "driver never accepted SSH via '$DRIVER_SSH' (150s)"
}

tf_bin() {
  if [ -n "${TF:-}" ]; then printf '%s' "$TF"; return; fi
  if command -v terraform >/dev/null 2>&1; then printf 'terraform'; return; fi
  if command -v tofu >/dev/null 2>&1; then printf 'tofu'; return; fi
  die "neither terraform nor tofu found on PATH"
}

require_cloud() {
  case "${CLOUD:-}" in
    gcp|aws) ;;
    *) die "CLOUD must be gcp or aws (got '${CLOUD:-}'). Example: make CLOUD=gcp $1" ;;
  esac
}

# Read a simple `key = "value"` assignment from the tfvars files of a Terraform root.
tfvar() { # tfvar <root-dir> <name>
  local f v
  for f in "$1"/terraform.tfvars "$1"/*.auto.tfvars; do
    [ -f "$f" ] || continue
    v="$(grep -E "^[[:space:]]*$2[[:space:]]*=" "$f" | tail -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"#]*)"?.*$/\1/' | sed 's/[[:space:]]*$//')"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}
