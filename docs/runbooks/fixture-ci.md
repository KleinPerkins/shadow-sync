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

The registered per-suite timeouts request cooperative cancellation of a suite;
they are ceilings, not reserved execution time or a promise that a unit may use
the sum of every suite maximum. Workflow job deadlines separately bound the whole
hosted execution, including stuck cleanup. The observer retains its original child
while cleanup drains; it has no forced-kill-after-timeout path. A job reaching its
hard deadline has failed qualification and cannot provide complete evidence or
admit another suite. Current shard counts and hard deadlines are a conservative
initial configuration; change them only from measured hosted durations while
preserving full-equivalence and cleanup gates.

Every PR, main push and weekly qualification runs mandatory coverage. Direct argv
commands retain source/run/attempt-bound receipts and actual case rosters. The
always-evaluated aggregate recomputes the expected matrix and rejects absent,
stale, failed, skipped, cancelled, duplicate, zero-test or incomplete evidence.
A suite that reaches its cooperative timeout still fails qualification. After
its exact bound completion marker and original child reap are verified, the unit
may collect evidence from subsequent independent suites; the unit remains failed.
Observer-integrity failures, observer interrupts and unverified cleanup stop
subsequent admission. This differs from the hosted job hard deadline, which cannot
supply complete evidence. App credentials are unavailable to this source workflow. Artifacts retain fixture evidence for
14 days; no local user inventory, credentials, installed state or screenshots are
inputs.

Fixture-only isolation governs test inputs and probes: disposable repositories,
homes, state and remotes, plus injected system adapters. The qualified OS,
libraries, toolchain and pinned runtime resources supply the host baseline.
The profiles enforce the existing home-read, write, execution, network and foreign
fixture-namespace restrictions and their denial canaries. Other host file reads
are not globally default-denied; the profiles do not claim a hermetic OS-read
allowlist. CI and fixture code must continue to avoid probing real user inventory,
credentials, installed product state, screenshots and protected repositories.

Native execution requires macOS26 arm64 and the exact Xcode26.6 baseline in
ADR0004. A local Command Line Tools installation is insufficient. These files do
not establish hosted qualification, review admission, App activation, merge,
installation, release or desktop/physical-input acceptance. Protected bootstrap
and exact-head hosted routine/transition evidence remain separate gates.
