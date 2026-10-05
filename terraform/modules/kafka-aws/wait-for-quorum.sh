#!/usr/bin/env bash
# Readiness gate for the Kafka module. Runs on the operator laptop via
# Terraform local-exec. SSHes to the driver VM and waits until
# kafka-metadata-quorum.sh reports a healthy quorum and exactly
# EXPECTED_BROKERS brokers answer on the INTERNAL listener.
#
# Env: DRIVER_IP SSH_KEY BOOTSTRAP EXPECTED_BROKERS TIMEOUT_SECONDS
set -euo pipefail

: "${DRIVER_IP:?DRIVER_IP is required}"
: "${SSH_KEY:?SSH_KEY is required}"
: "${BOOTSTRAP:?BOOTSTRAP is required}"
EXPECTED_BROKERS="${EXPECTED_BROKERS:-3}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"

if [[ ! -r "$SSH_KEY" ]]; then
  echo "FAIL: ssh private key not readable: $SSH_KEY" >&2
  exit 1
fi

ssh_cmd=(ssh -i "$SSH_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o BatchMode=yes
  "ubuntu@${DRIVER_IP}")

remote=$(cat <<REMOTE
set -o pipefail
[ -x /opt/kafka/bin/kafka-metadata-quorum.sh ] || { echo "kafka not installed yet"; exit 10; }
/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server '${BOOTSTRAP}' describe --status >/dev/null 2>&1 || { echo "quorum not ready"; exit 11; }
/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server '${BOOTSTRAP}' 2>/dev/null | grep -c '(id: '
REMOTE
)

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
attempt=0
echo "waiting up to ${TIMEOUT_SECONDS}s for ${EXPECTED_BROKERS} Kafka brokers via driver ${DRIVER_IP}"
while :; do
  attempt=$((attempt + 1))
  if out=$("${ssh_cmd[@]}" "$remote" 2>/dev/null); then
    count=$(printf '%s\n' "$out" | tail -n1 | tr -d '[:space:]')
    if [[ "$count" == "$EXPECTED_BROKERS" ]]; then
      echo "OK: quorum healthy, ${count} brokers listed (attempt ${attempt})"
      "${ssh_cmd[@]}" "/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server '${BOOTSTRAP}' describe --status" || true
      exit 0
    fi
    echo "attempt ${attempt}: ${count} broker(s) listed, want ${EXPECTED_BROKERS}"
  else
    echo "attempt ${attempt}: driver or quorum not ready yet"
  fi
  if (( $(date +%s) >= deadline )); then
    echo "FAIL: Kafka quorum not ready after ${TIMEOUT_SECONDS}s. Check: ssh -i ${SSH_KEY} ubuntu@${DRIVER_IP} 'sudo journalctl -u kafka-showcase-setup -b'" >&2
    exit 1
  fi
  sleep 15
done
