---
{"approval":{"actor":"Codex under owner-delegated execution authority, 2026-11-02","date":"2026-11-02","review_sha256":"83d47d1a41e91d05ddb8f7d2a364783872ee7c391f882ec678aee962c4afa05e"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-512104a0-be6d-5e63-a75d-d9ded6e32c49","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# Permanent ShadowSync technical identity

## Context

ShadowSync already has its final product name, but legacy technical identifiers span packaging, launch authority, state, schemas, commands, logs, fixtures, and development tooling. Keeping two active identities would create ambiguous authority, split locks, overlapping hosts, and indefinite migration risk.

## Decision

The permanent active identity is:

- repository and package identity: `shadow-sync`;
- product and executable name: `ShadowSync`;
- application: `ShadowSync.app`;
- bundle and active service namespace: `com.kleinperkins.shadow-sync`; and
- lifecycle coordinator signing identifier: `com.kleinperkins.shadow-sync.lifecycle-coordinator`.

New production writes, launch registrations, locks, sockets, logs, state schemas, environment protocols, commands, artifacts, tags, feeds, and release metadata use only the permanent identity.

The legacy `dev-main-sync` and `com.kleinperkins.dev-main-sync` families are allowed only in file-specific, token-specific:

- installation and state migration readers;
- compatibility fixtures;
- immutable or clearly derived historical evidence; and
- bounded pre-commit recovery that may restore byte-exact, verified legacy application, property-list, and state preimages only to an inert, stopped condition.

Recovery must not create new semantic old-format writes, admit repository work under the legacy identity, register or start a legacy launch route, or automatically reactivate an unsafe legacy host. After transaction commit, recovery repairs forward unless downgrade compatibility is separately proved.

Legacy exceptions require a reason, owner, validation, and retirement class. A directory-wide or repository-wide exclusion is not acceptable.

## Migration and retirement

The lifecycle coordinator performs the identity transition transactionally. It must prevent simultaneous old/new operation authority, preserve the effective lock lineage while state moves, and refuse ambiguous installations or state. Source authority must be handed off and production mutation by the source installer disabled before live migration. At the verified transition, the old launch identity is stopped and removed before the new identity is admitted.

The two-verified-release and 90-day retention window applies to migration readers, compatibility wrappers, and non-executable recovery archives—not to active legacy launch routes. Final compatibility retirement occurs only after verified migration and installed-update evidence, known-installation review, the full retention window, and a separate retirement record. Historical data readers may remain when needed to read preserved records, but they must never launch, register, or create new semantic writes under the legacy identity.

The first planned standalone candidates are:

- `0.10.0`, build `15`: signed standalone migration candidate; and
- `0.10.1`, build `16`: independently signed installed-update proof.

Build numbers increase monotonically and are never reused after allocation.

## Verification

A repository-owned technical-identity check must scan tracked paths and content, generated property lists and manifests, executable strings, signing identifiers, schemas, commands, environment keys, artifacts, and active cross-references.

Verification must prove:

- no unintended active legacy identity remains;
- every legacy occurrence is on the exact allowlist;
- production excludes testing-only routes;
- new writes use only the permanent identity;
- the old launch identity is absent before new admission; and
- migration and recovery never produce two active hosts or two effective lock namespaces.

## Scope boundary

This decision does not rename stable `ShadowSync` module or product names merely for consistency. It does not authorize cleanup beyond identity-verified product-owned residue, migrate arbitrary user data, or transfer Login Item registration implicitly.

## Consequences

The complete identity change is larger than a bundle-ID edit, but it produces one long-term operational identity and a finite compatibility surface. Release, installation, update, retirement, and UAT remain separate evidence gates; passing the rename checks proves none of them by itself.
