---
{"approval":{"actor":"Codex under owner-delegated execution authority, 2026-11-02","date":"2026-11-02","review_sha256":"5e0e0421b7c78978fb2ec23fbcd7a8103937487dacf3687330b69b675918a4ac"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-cd6d27a5-b469-567a-8c42-ed69e4007a13","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# Installation, lifecycle, and update authority

## Context

ShadowSync needs source-independent installation, transactional identity migration, recoverable replacement, and signed updates. Source installers and application-local update logic cannot safely own a transition that replaces the application while preserving process, lock, state, and publisher authority.

Installed activation also depends on external safety authorities. Generic protection semantics remain owned by AWA; concrete deployment policy remains outside the public repository. ShadowSync must consume verified policy rather than copy it or substitute a permissive fallback.

## Decision

Retain the managed-LaunchAgent/manual-router architecture. A signed, bundled `ShadowSyncLifecycleCoordinator` is the sole authority for:

- first installation;
- legacy identity migration;
- repair and removal;
- application replacement;
- interrupted-transaction recovery; and
- coordination of signed Sparkle updates.

Production installation requires neither a source checkout nor a compiler. Source installers become fixture/development tools and must refuse production mutation.

After the permanent identity is established, Sparkle is the sole normal distribution-update mechanism. The initial integration must pin Sparkle 2.10.1 until an independently reviewed dependency update supersedes it. A failed signing, migration, coordinator, or Sparkle qualification leaves delivery incomplete; it never authorizes a source-updater fallback or disabled signature verification.

Startup remains explicit user opt-in through normal macOS Login Items behavior. Identity migration does not imply automatic transfer of prior registration.

## Transaction invariants

Every installation, migration, repair, removal, and update transaction must:

- authenticate the coordinator and application publisher;
- stop new operation admission and drain owned work;
- preserve one effective operation/lifecycle authority across replacement;
- never signal an unverified process or delete a contended lock;
- persist and fsync an idempotent transaction journal before consequential mutation;
- preserve recognized authority, selection, log, retention, and user-owned data;
- refuse malformed, newer, ambiguous, or conflicting state without reset;
- verify staged readiness without repository access or network work;
- commit only after application, state, launch identity, signature, and readiness converge; and
- leave a recoverable transaction when interrupted.

Bundled frameworks may contain only the separately reviewed, sealed internal symlinks. Verification must reject escapes, unexpected files, unexpected nested code, wrong publishers, or weakened library validation.

## Admission-safe migration order

Legacy code can resolve its state path again after an initial admission. Renaming state while a legacy entrypoint remains runnable can therefore create a second lock namespace. The coordinator must close those entrypoints before moving state; path absence alone is not exclusion.

1. Make the canonical legacy source installer unavailable or fail closed through its owning authority, and verify that source-attested lifecycle routes are closed.
2. Cooperatively drain verified legacy hosts, workers, and owned children. Acquire the existing `latest.log` namespace lock exclusively from an unheld state, with no lower-order lock held and no shared-to-exclusive upgrade.
3. Atomically retire the canonical legacy application into verified, owner-only, same-parent rollback storage. Prove that in-flight and blocked legacy entrants are reaped before moving state. Label absence, a missing socket, or a sent signal alone is insufficient; unknown identity or contention refuses the transition.
4. Acquire the existing lifecycle, operation, run, and launcher locks in the reviewed order without creating or replacing them. Atomically rename the same old state directory to the new state root while retaining every descriptor and verifying unchanged directory, log, and lock device/inode identities.
5. Translate recognized active documents atomically while preserving historical bytes and user intent. Publish the new application only against complete state; publish its LaunchAgent last. Release only the admission locks required for authenticated staged readiness, retaining the same effective operation lock until readiness commits.
6. Before transaction commit, rollback retires the candidate and renames the same namespace back before restoring the old application. The old application remains stopped; rollback never loads or kickstarts its LaunchAgent or recreates, restores, or enables Login Item startup.

There is no rollback-side namespace parking followed by new lock creation. Recovery must use the retained lock identities. Fault-injection coverage must include in-flight manual, managed-host, worker, lifecycle-remove, and source-installer entrants, plus interruption at every publication boundary. These are implementation proof obligations, not claims that a deployed migration has already passed.

## External safety prerequisites

Installed activation is blocked until the independently owned P4 chain is evidenced:

1. required controller maintenance-base support is rebuilt from current authority, deployed, and verified;
2. the governed AWA v1.8.2 hard-no-touch maintenance release is enrolled and released;
3. the exact AWA pin and runtime are installed and verified through their authorized process;
4. concrete deployment policy and its compatibility binding are merged, deployed, and verified; and
5. a compatible ShadowSync policy consumer is ready.

The application remains stopped until the chain is complete. Missing, stale, malformed, incompatible, or unverifiable policy fails closed before candidate metadata access. No copied matcher, Swift fallback, or removal of protection policy is allowed.

The public product may point to AWA’s canonical [host-overlay decision](https://github.com/KleinPerkins/awa/blob/main/docs/adr/0002-awa-dev-overlay.md) and [integrity lifecycle decision](https://github.com/KleinPerkins/awa/blob/main/docs/adr/0020-awa-integrity-surveillance-and-lifecycle.md) without embedding concrete deployment values.

## Candidate and update proof

`0.10.0` build `15` is the first signed standalone migration candidate. `0.10.1` build `16` is the first independently signed installed-update proof. Both remain qualification candidates until their distinct gates pass.

Build 15 must prove clean source-free installation and supported legacy migration. Build 16 must prove an installed signed 15→16 update using identical promoted bytes. Publishing, notarization, installation, successful update, channel promotion, legacy retirement, and UAT acceptance are distinct outcomes.

## Recovery

Before readiness commit, restore verified preimages only to a stopped state and preserve the same lock authority. After readiness commit, repair forward. A downgrade after new-version operations is prohibited unless state-format compatibility is proved.

Recovery from a signed distribution may repair a missing or unusable installation. It must not destroy unknown data, recreate prior startup registration silently, or reactivate an unsafe legacy host.

## Consequences

The coordinator and updater add packaging and fault-injection work, but create one source-free mutation authority and a recoverable replacement boundary. A signed-release milestone requires its own signing, notarization, provenance, and release-integrity evidence. Installation, migration, installed update, channel promotion, legacy retirement, and physical/UAT acceptance each retain their own completion criteria; none is a prerequisite for a correctly evidenced signed-release milestone, and no milestone implies product acceptance.
