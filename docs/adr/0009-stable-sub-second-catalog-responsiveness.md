---
{"approval":{"actor":"Codex under owner-delegated execution authority; records the accepted strict sub-second responsiveness amendment without claiming operator hash inspection","date":"2026-11-18","review_sha256":"d7df3560f6d09c18413135300ddb931f58dba0124ec76161926d4a3b76ad953d"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-d45994dc-f254-50b3-8b7d-3337d64ee933","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-9f5f6f72-9ec1-5a9a-b8d2-f093a70fc428","type":"adr","version":1}
---
# Stable sub-second catalog responsiveness

## Context

The catalog admits a governed root before reading its directory names, then classifies discovered paths before metadata access. The accepted external-classifier architecture in ADR 0006 adds authenticated helper setup, execution, validation and complete cleanup to that path. Its inherited 750 ms aggregate responsiveness limit is superseded by this decision.

## Decision

A complete usable catalog must return in strictly less than one second. The aggregate limit is 1,000,000,000 monotonic nanoseconds; equality is expired. Authentication and setup, all fresh classification and resource validation, metadata inspection, and owned-helper cleanup consume the same original absolute deadline. A transport maximum, rebinding call or later stage never renews that deadline. No helper may survive completion, cancellation or refusal.

This changes the responsiveness requirement only. All other decisions in [ADR 0006](0006-bounded-policy-classification-before-repository-selection.md) remain in force: fail-closed policy admission; root, intermediate and metadata access ordering; exact request/response and snapshot binding; bounded work; protected-path isolation; cancellation; authenticated child custody; complete reaping and cleanup; and rejection of partial evidence. An expired or incomplete catalog is degraded and cannot enable operations. A safe refusal is not a passing responsiveness result.

The prior 750 ms catalog assertions in preserved approved specifications and historical evidence describe the superseded requirement. Their frozen bytes remain unchanged; this successor supplies the current timing contract. This decision grants no installation, signing, release, runtime activation or product UAT authority.

## Verification

Keep the original cold caller fixtures, all safety/refusal cases and complete hosted runtime partitions. Assert strict sub-second completion at the caller boundary, including setup and cleanup, and retain measured catalog durations. Exercise just-below, equal and above-limit boundary behavior and refusal under a shorter original deadline. Use existing repeatable fixture validation to report the observed cold timings and cleanup honestly. Local timing and synthetic CI do not establish the separately governed physical first-screen, representative-inventory or installed-product UAT outcomes in ADR 0006.

## Consequences

The source and tests use a single strict sub-second catalog responsiveness budget. Existing material critical-path improvements remain; this amendment does not claim every environment or inventory will complete in time. A current measured breach remains a defect or explicit degraded result, never permission to weaken policy or cleanup checks.
