# Contributing

Issues are welcome: a step that did not work on a fresh account, a quota we did not list, a
trap we did not document, a cost estimate that was off. Please include the cloud, the region,
the `kmq version` output, and the exact line of output you saw. Redact project ids, account
ids, IP addresses and license keys before posting.

Pull requests are reviewed. Before opening one:

1. Run `make lint` (Terraform format check, shellcheck, `go vet` and a Linux build of the seeder,
   markdown link check).
2. Run `make leak-scan`. It must end with `✅ leak-scan clean`. It greps for internal project names, zone
   defaults, hard-coded IP addresses, private registry hosts and personal identifiers; a hit
   blocks the merge.
3. Keep every version pinned. A change to `versions.env` must come with a note of what you
   re-ran to confirm the pin works.
4. Do not add defaults for `project_id`, `region`, `zone` or `operator_cidr`. Do not widen
   any firewall rule.
5. Do not claim production qualification anywhere. The "proves / does not prove" box in the
   README is binding for all documentation.

Changes that alter the migration flow must be checked against `kmq <command> --help` of the
pinned version, not against memory. Every prompt must keep the mandatory header from
`prompts/_header.md` verbatim.

By contributing you agree that your contribution is licensed under the Apache License 2.0
in `LICENSE`.
