#!/usr/bin/env bash
#
# kmq-install.sh — install the kmq CLI at EXACTLY the version pinned in versions.env.
#
# If kmq is already on PATH at that version, nothing happens. Otherwise the public
# installer is run with --version, and the result is re-checked. Any mismatch is exit 1:
# the migration worker image must match the CLI version, and `kmq migrate job submit`
# refuses a mismatch, so a drifted kmq is not "close enough".
#
# Usage: scripts/kmq-install.sh
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_versions
: "${KMQ_VERSION:?KMQ_VERSION missing in versions.env}"
INSTALLER_URL="https://raw.githubusercontent.com/kubemq-io/kmq/main/install.sh"

# `kmq version -o json` prints {"version":"vX.Y.Z","commit":"..."}; the passive update
# check only runs on a TTY, but KMQ_NO_UPDATE_CHECK=1 pins that down for good measure.
installed_version() {
  command -v kmq >/dev/null 2>&1 || return 1
  KMQ_NO_UPDATE_CHECK=1 kmq version -o json 2>/dev/null | jq -r '.version // empty' 2>/dev/null
}

HAVE="$(installed_version || true)"
if [ "$HAVE" = "$KMQ_VERSION" ]; then
  say "✅ kmq $HAVE already installed ($(command -v kmq))"
  exit 0
fi
if [ -n "$HAVE" ]; then
  say "kmq $HAVE found, pin is $KMQ_VERSION — reinstalling"
else
  say "kmq not found — installing $KMQ_VERSION"
fi

say "+ curl -sSfL $INSTALLER_URL | sh -s -- --version $KMQ_VERSION"
curl -sSfL "$INSTALLER_URL" | sh -s -- --version "$KMQ_VERSION"
hash -r 2>/dev/null || true

NOW="$(installed_version || true)"
if [ -z "$NOW" ]; then
  die "kmq is not on PATH after install. The installer prints where it put the binary; add that directory to PATH and re-run."
fi
[ "$NOW" = "$KMQ_VERSION" ] || die "kmq reports $NOW after install, pin is $KMQ_VERSION. Another kmq earlier on PATH? ($(command -v kmq))"
say "✅ kmq $NOW installed ($(command -v kmq))"
