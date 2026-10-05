#!/usr/bin/env bash
# Readiness gate run by Terraform (null_resource.kafka_ready) from the operator laptop.
# Loops over SSH to the driver until the KRaft quorum answers and 3 brokers are registered.
set -euo pipefail

: "${SSH_COMMAND:?}" "${USE_GCLOUD:?}" "${BOOTSTRAP:?}" "${TIMEOUT_SECONDS:=600}"

remote() {
  if [[ "${USE_GCLOUD}" == "1" ]]; then
    # shellcheck disable=SC2086
    ${SSH_COMMAND} --command "$1"
  else
    # shellcheck disable=SC2086
    ${SSH_COMMAND} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$1"
  fi
}

# Remote script; BOOTSTRAP is spliced in on purpose, the rest stays literal.
# shellcheck disable=SC2016
check='set -e
test -x /opt/kafka/bin/kafka-metadata-quorum.sh
/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server '"${BOOTSTRAP}"' describe --status >/dev/null
n=$(/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server '"${BOOTSTRAP}"' 2>/dev/null | grep -c "id: [0-9]")
test "$n" -eq 3'

deadline=$((SECONDS + TIMEOUT_SECONDS))
attempt=0
echo "waiting up to ${TIMEOUT_SECONDS}s for Kafka quorum via ${BOOTSTRAP}"
while (( SECONDS < deadline )); do
  attempt=$((attempt + 1))
  if remote "${check}" >/dev/null 2>&1; then
    echo "kafka ready: quorum answered and 3 brokers registered (attempt ${attempt})"
    exit 0
  fi
  echo "not ready yet (attempt ${attempt}); retrying in 15s"
  sleep 15
done
echo "FAIL: Kafka quorum not ready after ${TIMEOUT_SECONDS}s" >&2
exit 1
