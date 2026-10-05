# Security policy

This repository contains infrastructure code that creates cloud resources in **your** account
and a Kafka cluster that is deliberately plaintext and unauthenticated. It is a throwaway
showcase, not a hardened deployment. The protection is network scope: every inbound path is
limited to one IPv4 address (yours) or to the private network, and nothing is opened to
`0.0.0.0/0`.

## Reporting a vulnerability

If you find a problem in this repository — a rule that opens wider than documented, a secret
that could leak into state or logs, a teardown path that leaves a billable resource behind —
please do not open a public issue. Email **security@kubemq.io** (see [kubemq.io](https://kubemq.io)
for the current contact if that address changes). Include the file and line, what you
observed, and how to reproduce. We aim to acknowledge within three business days.

Vulnerabilities in the KubeMQ server, operator, Helm chart or `kmq` command-line tool belong
to those projects; the same address reaches the right team.

## What we will not treat as a vulnerability

- Kafka being plaintext inside the dedicated VPC. That is by design and documented.
- Cost incurred by a rig you did not tear down. The teardown gate is documented in
  `docs/08-teardown-and-cost.md`.
- Issues that require `operator_cidr` to be set to a range wider than this repository allows.

## Scanning

CI runs `scripts/leak-scan.sh` and a secret scanner over the tree and history. Never commit
`*.tfvars` (only `*.tfvars.example`), `.rig/`, kubeconfig files, state files or logs; the
`.gitignore` excludes them.
