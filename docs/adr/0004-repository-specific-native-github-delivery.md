---
{"approval":{"actor":"Codex under owner-delegated execution authority, 2026-11-02","date":"2026-11-02","review_sha256":"f5366ec05a0c6e3819bb39c3f79cb10cafcb35d7be3fadfd4741d5a7332c6fe4"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-bde4e827-df96-5f47-801e-85d97ceb0dfe","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# Repository-specific native GitHub delivery

## Context

The intended ShadowSync repository requires macOS-native compilation, substantive runtime verification, signed packaging, and release administration. Existing runnerless policies for other repositories remain valid and must not be weakened or generalized to accommodate this product.

Ordinary implementation delivery, protected automation administration, and product release approval have different authorities. Combining them would either over-privilege ordinary pull-request automation or add an unnecessary operator review gate to ordinary implementation.

## Decision

Only the public `KleinPerkins/shadow-sync` repository receives the narrow exception to use free standard GitHub-hosted Actions runners and the approved reviewer-App delivery pattern. The exception has been accepted by the host-policy owner; App installation, required checks, and delivery qualification remain separate evidence gates.

The exception does not apply to any other repository and does not modify an existing controller fleet or runnerless policy by implication.

Actions must use:

- standard GitHub-hosted runners only;
- no larger or self-hosted runners;
- no paid usage;
- read-only default token permissions;
- full commit pins for third-party actions;
- bounded artifact retention; and
- trusted default-branch code for privileged automation.

Initial native support is arm64 on macOS 26 with deployment target 26.0. Intel, universal, macOS 15, and macOS 27 support are not claimed. The build baseline is Swift tools 6.2 and Xcode 26.6 with its bundled toolchain.

## Ordinary pull-request authority

For an ordinary eligible implementation pull request, the reviewer App alone:

1. verifies the exact current head and required check integration;
2. verifies open/non-draft, same-repository, trusted-author, complete-file-list, and protected-path eligibility;
3. approves only that exact eligible head; and
4. arms native squash auto-merge.

Changed heads, stale approvals, missing or skipped checks, incomplete file lists, untrusted pull requests, protected paths, and race conditions must refuse. Ordinary implementation pull requests do not acquire a generic operator code-review gate.

Release-please and dependency pull requests follow their explicit policies rather than an ordinary-author shortcut.

## Protected administration and release authority

Protected workflows, policy, signing, installer/update authority, dependency locks, entitlements, release metadata, and feed publication require technical review and the prescribed owner/admin administration path. The reviewer App does not acquire protected administration authority.

Release-environment approval controls credential availability and release activity. It is separate from ordinary pull-request approval and does not constitute installation, channel promotion, retirement, or UAT acceptance.

Repository protections must include squash-only linear history, strict exact-head required checks, stale-approval dismissal, resolved conversations, force-push/deletion protection, protected release tags, and immutable releases before the first product release. Settings and rulesets must be verified by read-back rather than inferred from configuration requests.

## Required CI contract

The planned aggregate gate covers:

- quality and public-disclosure checks;
- package compilation;
- substantive runtime safety;
- native and lifecycle fixtures;
- package/signature structure; and
- an always-evaluated aggregate that rejects missing, skipped, cancelled, failed, zero-test, or incomplete mandatory results.

Public CI uses disposable repositories, homes, state, remotes, and injected system adapters. It never probes real host inventory, credentials, installed state, screenshots, or protected repositories.

## Evidence and consequences

The exception is not operational merely because workflow files exist. It requires accepted classification by the owning policy authority, settings read-back, successful exact-head CI, negative eligibility tests, and a verified ordinary native squash merge.

Source merge, CI operation, reviewer-App delivery, protected administration, signed release, installed migration, installed update, promotion, retirement, and UAT are separate outcomes. Failure in one cannot be converted into authority for another.
