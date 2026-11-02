---
{"approval":{"actor":"Codex under owner-delegated execution authority, 2026-11-02","date":"2026-11-02","review_sha256":"b880accde62edb5632399e9652aea0ca7015520a41f0a7d6d693f8f2dfb85a98"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-a1b1f9a6-e7f2-5fce-9646-2fb3c9354425","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# Standalone extraction and provenance

## Context

ShadowSync is intended to become an independently governed public macOS product. Its current implementation is held under a broader private source authority that also contains unrelated material and private operational context. Publishing that history or mechanically mirroring the broader tree would disclose material outside the product boundary and would couple the product to an authority it is meant to leave.

Public visibility is a permanent disclosure boundary. A proprietary license reserves source and original-art rights, but does not make publicly visible source confidential. Third-party components retain their own licenses and notice obligations.

## Decision

The public product repository is `KleinPerkins/shadow-sync`. Repository creation and configuration are separate from product source handoff and qualification.

Product source will enter that repository through a reviewed, allowlisted snapshot with fresh public history. It will not use a repository mirror, a filtered import of private history, or an import of unrelated source.

The extraction has two provenance layers:

1. An owner-private receipt records the exact source authority, source identity, path mapping, file modes, byte hashes, transformations, exclusions, and sensitive review evidence.
2. A public provenance record identifies the published target content, target paths, modes, hashes, third-party provenance, and validation results without exposing the private source authority, private topology, or review ledger.

A committed provenance record must not claim the hash of its own containing Git tree. It may describe a preceding content commit/tree, or an external attestation may describe the final manifest-bearing commit.

The public snapshot must:

- omit private history, host configuration, user state, credentials, logs, screenshots, machine-specific paths, and unrelated material;
- externalize deployment policy without weakening fail-closed protections;
- retain original third-party notices and reviewed asset provenance;
- preserve executable modes and reject unreviewed source symlinks, submodules, sidecar files, and unmanifested content;
- allow only separately reviewed, sealed internal symlinks in packaged frameworks;
- distinguish reviewed synthetic secret-shaped fixtures from live-secret evidence; and
- record every intentional byte transformation.

The private source remains frozen during handoff. The standalone repository becomes the sole implementation authority only after transformed-source parity, standalone verification, and the explicit handoff evidence pass. Foundation publication alone does not transfer source authority.

## Scope boundary

The extraction preserves existing product behavior and open UAT. It does not authorize:

- a general interface redesign;
- broader Git repair or cleanup permission;
- broader operating-system or architecture support;
- live installation, update, release, or retirement;
- copying generic policy implementations into the product; or
- importing raw private plans, ADRs, automation, or receipts.

Sanitized historical summaries may be adopted as derived public records. They must be labeled as derived and must not reproduce private topology or evidence.

## Licensing

The repository is public and proprietary. Public source visibility grants no open-source license. Source and original artwork remain rights-reserved under the repository license; third-party material remains under its identified terms. Binary-use and binary-distribution terms are separate release decisions and are not granted by source visibility.

## Consequences

- The public repository receives a clean, product-only history rather than the private development history.
- Publication incidents cannot be reversed by deleting a branch or release; correction uses ordinary public commits and disclosure.
- Useful private history remains with its original authority and is not duplicated as a second editable product source.
- Source extraction, repository governance, signed release, installed migration, installed update, legacy retirement, and UAT remain separate outcomes.

## Verification and recovery

Before source publication, verify the complete output tree against the allowlist and transformation manifest, perform bounded disclosure and secret review, validate third-party notices, and run standalone fixture-only verification. Absence claims must not rely on grep or a scanner alone.

Before public source exists, correct an unpublished candidate in private staging. After publication, preserve the public record and repair forward with normal corrective commits. No extraction result authorizes installation or release without its separate gates.
