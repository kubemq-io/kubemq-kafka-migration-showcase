#!/usr/bin/env bash
#
# bootstrap-node.sh — runs ON a Kafka node (broker or driver) as root, on EVERY boot,
# from the kafka-showcase-setup.service oneshot that cloud-init installs.
#
# Reads /etc/kafka-showcase/node.env (written by cloud-init from Terraform):
#   KAFKA_VERSION, KAFKA_SHA512, MOUNT_NVME=1|0, NVME_MODEL_REGEX, (KAFKA_SCALA optional)
#
# Does, idempotently:
#   1. installs a headless Java 17 runtime plus curl/tar/lsblk/mkfs tools if missing
#   2. downloads the Apache Kafka tarball (dlcdn first, archive.apache.org fallback),
#      verifies its SHA-512 against KAFKA_SHA512, extracts to /opt/kafka_<scala>-<ver>
#      and points /opt/kafka at it — skipped when /opt/kafka/bin already exists
#   3. if MOUNT_NVME=1: finds exactly ONE block device whose MODEL matches
#      NVME_MODEL_REGEX, refuses the root device, formats it ext4 when it carries no
#      filesystem, and mounts it at /mnt/kafka-data (fstab entry with nofail)
#
# Refuses to guess: zero or more than one matching device is a hard failure.
set -euo pipefail

NODE_ENV=/etc/kafka-showcase/node.env
KAFKA_HOME=/opt/kafka
DATA_DIR=/mnt/kafka-data

log() { printf '[bootstrap-node] %s\n' "$*"; }
fail() { printf '[bootstrap-node] FAIL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "must run as root"
[ -f "$NODE_ENV" ] || fail "$NODE_ENV not found (cloud-init did not write it)"
# shellcheck disable=SC1090
source "$NODE_ENV"

: "${KAFKA_VERSION:?KAFKA_VERSION missing in $NODE_ENV}"
: "${KAFKA_SHA512:?KAFKA_SHA512 missing in $NODE_ENV}"
: "${MOUNT_NVME:?MOUNT_NVME missing in $NODE_ENV}"
KAFKA_SCALA="${KAFKA_SCALA:-2.13}"
TARBALL="kafka_${KAFKA_SCALA}-${KAFKA_VERSION}.tgz"
DIST="/opt/${TARBALL%.tgz}"
URL_PRIMARY="https://dlcdn.apache.org/kafka/${KAFKA_VERSION}/${TARBALL}"
URL_FALLBACK="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${TARBALL}"

# ---------------------------------------------------------------- 1. packages
install_pkgs() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    # On a fresh Ubuntu boot apt-daily / unattended-upgrades often hold the dpkg lock for
    # minutes; wait for it (apt >= 1.9.11) and retry the whole step a few times.
    local -a apt=(apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    local _try
    for _try in 1 2 3 4 5; do
      if "${apt[@]}" update -qq && "${apt[@]}" install -y -qq openjdk-17-jre-headless curl tar util-linux e2fsprogs >/dev/null; then
        return 0
      fi
      log "apt attempt $_try failed (lock held / mirror hiccup); retrying in 15s"
      sleep 15
    done
    fail "apt-get could not install the packages after 5 attempts"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q java-17-amazon-corretto-headless curl tar util-linux e2fsprogs >/dev/null 2>&1 \
      || dnf install -y -q java-17-openjdk-headless curl tar util-linux e2fsprogs >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q java-17-amazon-corretto-headless curl tar util-linux e2fsprogs >/dev/null
  else
    fail "no supported package manager (apt-get, dnf, yum)"
  fi
}
if ! command -v java >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
  log "installing Java 17 (headless) and tools"
  install_pkgs
fi
log "java: $(java -version 2>&1 | head -1)"

id kafka >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin kafka

# ---------------------------------------------------------------- 2. kafka dist
sha512_of() { sha512sum "$1" | awk '{print tolower($1)}'; }

if [ ! -x "$DIST/bin/kafka-server-start.sh" ]; then
  TMP="/opt/.${TARBALL}.partial"
  rm -f "$TMP"
  log "downloading $URL_PRIMARY"
  if ! curl -fsSL --max-time 600 -o "$TMP" "$URL_PRIMARY"; then
    log "primary download failed, trying $URL_FALLBACK (archive.apache.org is throttled; this can take a while)"
    curl -fsSL -o "$TMP" "$URL_FALLBACK" || fail "download failed from both $URL_PRIMARY and $URL_FALLBACK"
  fi
  GOT="$(sha512_of "$TMP")"
  WANT="$(printf '%s' "$KAFKA_SHA512" | tr -d ' \n' | tr '[:upper:]' '[:lower:]')"
  if [ "$GOT" != "$WANT" ]; then
    rm -f "$TMP"
    fail "SHA-512 mismatch for $TARBALL: got $GOT want $WANT"
  fi
  log "SHA-512 verified"
  tar xzf "$TMP" -C /opt
  rm -f "$TMP"
fi
ln -sfn "$DIST" "$KAFKA_HOME"
[ -x "$KAFKA_HOME/bin/kafka-server-start.sh" ] || fail "kafka distribution missing after extract ($DIST)"
mkdir -p /var/log/kafka && chown kafka:kafka /var/log/kafka
log "kafka $KAFKA_VERSION at $KAFKA_HOME"

# ---------------------------------------------------------------- 3. NVMe mount
if [ "$MOUNT_NVME" = 1 ]; then
  : "${NVME_MODEL_REGEX:?NVME_MODEL_REGEX missing in $NODE_ENV (required when MOUNT_NVME=1)}"
  mkdir -p "$DATA_DIR"
  if ! mountpoint -q "$DATA_DIR"; then
    # Root device: the disk behind the filesystem mounted at / (not the partition).
    ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
    ROOT_DISK=""
    if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
      ROOT_DISK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
      [ -n "$ROOT_DISK" ] || ROOT_DISK="$(basename "$ROOT_SRC")"
    fi

    # lsblk -d lists whole disks only; NAME then MODEL (model may contain spaces).
    MATCHES=()
    while IFS= read -r line; do
      name="${line%% *}"
      model="$(printf '%s' "${line#"$name"}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if printf '%s' "$model" | grep -Eq -- "$NVME_MODEL_REGEX"; then
        MATCHES+=("$name")
      fi
    done < <(lsblk -d -n -o NAME,MODEL)

    if [ "${#MATCHES[@]}" -eq 0 ]; then
      lsblk -d -o NAME,MODEL,SIZE >&2
      fail "no block device MODEL matches /$NVME_MODEL_REGEX/ — refusing to guess"
    fi
    if [ "${#MATCHES[@]}" -gt 1 ]; then
      lsblk -d -o NAME,MODEL,SIZE >&2
      fail "${#MATCHES[@]} block devices match /$NVME_MODEL_REGEX/ (${MATCHES[*]}) — expected exactly one, refusing to guess"
    fi
    DEV="/dev/${MATCHES[0]}"
    [ "${MATCHES[0]}" != "$ROOT_DISK" ] || fail "matched device $DEV is the root disk — refusing"
    [ -b "$DEV" ] || fail "$DEV is not a block device"

    if [ -z "$(blkid -o value -s TYPE "$DEV" 2>/dev/null || true)" ]; then
      log "formatting $DEV as ext4 (no filesystem present)"
      mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$DEV" >/dev/null
    else
      log "$DEV already has a filesystem ($(blkid -o value -s TYPE "$DEV"))"
    fi
    UUID="$(blkid -o value -s UUID "$DEV")"
    [ -n "$UUID" ] || fail "could not read UUID of $DEV"
    # A stopped-and-started VM gets a blank local disk with a NEW UUID: drop any stale
    # fstab line for the mount point so `mount $DATA_DIR` resolves to the live device.
    if ! grep -q "^UUID=$UUID " /etc/fstab; then
      sed -i "\| $DATA_DIR |d" /etc/fstab
      printf 'UUID=%s %s ext4 defaults,discard,nofail 0 2\n' "$UUID" "$DATA_DIR" >> /etc/fstab
    fi
    mount "$DATA_DIR" || mount -o defaults,discard "$DEV" "$DATA_DIR"
    log "$DEV mounted at $DATA_DIR (local NVMe: EPHEMERAL, data is lost if the VM is recreated)"
  else
    log "$DATA_DIR already mounted"
  fi
  mkdir -p "$DATA_DIR/data"
  chown -R kafka:kafka "$DATA_DIR"
  df -h "$DATA_DIR" | tail -1 | sed 's/^/[bootstrap-node]   /'
fi

log "ok: $(hostname) role=${ROLE:-?}"
