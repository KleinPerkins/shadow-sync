# Fixture-only CI source

The canonical registration is `config/ci-suites.json`. Regenerate it with
`python3 -I -B scripts/ci-registration.py --write`, then run the command without
`--write` to verify exact agreement with Python framework discovery, the runtime
registry and native fixture catalogs. Adding a test without regenerating the
registration fails quality. Compile-only Swift targets never supply runtime cases.

The five logical groups are quality, compile-package, runtime-safety,
native-and-lifecycle and package-contract. Existing tooling uses macOS-specific
fixture paths and process APIs, so all groups use standard macOS26 arm64 runners.
The initial count is one shard per group, pending hosted duration measurements.
No speedup is claimed. Initial registration and every registration change require
all shards plus a separately executed full run for every group.

Every PR, main push and weekly qualification runs mandatory coverage. Direct argv
commands retain source/run/attempt-bound receipts and actual case rosters. The
always-evaluated aggregate recomputes the expected matrix and rejects absent,
stale, failed, skipped, cancelled, duplicate, zero-test or incomplete evidence.
Commands cannot admit the next suite after unverified cleanup. App credentials
are unavailable to this source workflow. Artifacts retain fixture evidence for
14 days; no local user inventory, credentials, installed state or screenshots are
inputs.

Native execution requires macOS26 arm64 and the exact Xcode26.6 baseline in
ADR0004. A local Command Line Tools installation is insufficient. These files do
not establish hosted qualification, review admission, App activation, merge,
installation, release or desktop/physical-input acceptance. Protected bootstrap
and exact-head hosted routine/transition evidence remain separate gates.
