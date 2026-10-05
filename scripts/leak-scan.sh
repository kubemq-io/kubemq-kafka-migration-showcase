#!/usr/bin/env bash
#
# leak-scan.sh — grep the tree for strings that must never appear in a public repo:
# internal project ids, zones, labels, name prefixes, private IP ranges, literal /32
# addresses, private registries and repos, internal skill names, e-mail addresses.
#
# Usage: scripts/leak-scan.sh [--strict] [PATH...]
#   --strict  also scan build-time planning files if present (PLAN.md, CONTRACT.md)
#
# Lines matching a regex in scripts/leak-scan.allow (one per line, # comments) are
# ignored — use it ONLY for documented public strings. Exit 1 on any hit.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW="$ROOT/scripts/leak-scan.allow"
STRICT=0
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PATHS+=("$1"); shift ;;
  esac
done
[ "${#PATHS[@]}" -gt 0 ] || PATHS=("$ROOT")

PATTERNS=(
  '--project[ =]+kubemq\b'                         # gcloud --project kubemq
  'project(_id)?[[:space:]]*[=:][[:space:]]*"?kubemq"?([[:space:]]|$)'  # project_id = "kubemq"
  'us-central1'                                    # internal default region/zone
  'bench='                                         # internal rig label
  '\bkfk-'                                         # internal rig VM names
  '10\.128\.'                                      # internal default-network subnet
  '\b([0-9]{1,3}\.){3}[0-9]{1,3}/32\b'             # literal operator IP
  'pkg\.dev'                                       # Artifact Registry (except the allowlisted public image)
  'gcr\.io'
  '\.work/'                                        # internal working directory
  '\bbench/'                                       # internal rig directory
  'charts-next/examples'
  'kubemq-server'                                  # private repo
  'sales-issued'
  "(^|[[:space:]\`\"'(])/kafka-gcp\\b"               # internal skill names (/kafka-gcp, not modules/kafka-gcp)
  "(^|[[:space:]\`\"'(])/supervise\\b"
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'   # e-mail addresses
)

GREP_ARGS=(-rnIE --exclude-dir=.git --exclude-dir=.terraform --exclude-dir=.rig --exclude-dir=node_modules --exclude-dir=.idea
           --exclude=leak-scan.sh --exclude=leak-scan.allow --exclude='*.tfstate*' --exclude='*.lock.hcl')
if [ "$STRICT" = 0 ]; then GREP_ARGS+=(--exclude=PLAN.md --exclude=CONTRACT.md); fi
for p in "${PATTERNS[@]}"; do GREP_ARGS+=(-e "$p"); done

# Scan only what git would publish: tracked files plus untracked files that are not ignored.
# Gitignored run state (tfvars, .rig/, migration/) is never committed and would otherwise
# produce false hits on a developer machine.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HITS="$(cd "$ROOT" && git ls-files --cached --others --exclude-standard -z -- "${PATHS[@]}" 2>/dev/null \
          | xargs -0 grep "${GREP_ARGS[@]}" -- 2>/dev/null || true)"
else
  HITS="$(grep "${GREP_ARGS[@]}" -- "${PATHS[@]}" 2>/dev/null || true)"
fi
if [ -f "$ALLOW" ]; then
  ALLOW_RX="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" || true)"
  if [ -n "$ALLOW_RX" ]; then
    HITS="$(printf '%s\n' "$HITS" | grep -vE -f <(printf '%s\n' "$ALLOW_RX") || true)"
  fi
fi
HITS="$(printf '%s\n' "$HITS" | grep -v '^$' || true)"

if [ -z "$HITS" ]; then
  echo "✅ leak-scan clean (${#PATTERNS[@]} patterns, strict=$STRICT)"
  exit 0
fi
N="$(printf '%s\n' "$HITS" | wc -l | tr -d ' ')"
echo "⛔ leak-scan: $N hit(s). Remove the string, or (only for a documented public value) add a regex to scripts/leak-scan.allow:" >&2
printf '%s\n' "$HITS" | sed "s|^$ROOT/||" >&2
exit 1
