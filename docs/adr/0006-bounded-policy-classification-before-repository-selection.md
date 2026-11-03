---
{"approval":{"actor":"Codex under owner-delegated execution authority; prospective reconciliation of the accepted external-classifier architecture, not an assertion of operator hash inspection","date":"2026-11-02","review_sha256":"d20064b5604b9fa9ce899a4434e02143d383b84302ada3ec4b214a5444f7b53a"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-9f5f6f72-9ec1-5a9a-b8d2-f093a70fc428","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# Bounded policy classification before repository selection

## Context

Extraction retains the lightweight repository chooser and its safety and latency requirements. The inherited chooser contract prohibited all child processes before Continue. The accepted standalone policy architecture requires the exact external AWA Python classifier before any candidate filesystem access. Literal compliance with both is impossible: the classifier is a child process even when it performs no repository operations.

This record resolves that conflict narrowly for P5 and requirements REQ-SF-02, REQ-SF-04, REQ-SF-05 and REQ-SF-06. It changes neither product scope nor the external release and activation gates in ADR 0005. It does not qualify the current implementation, select an installed interpreter, or accept native performance.

## Decision

Permit only the verified, bounded, read-only AWA policy helper before Continue. Replace the inherited blanket zero-child count with a separately counted policy-helper allowance; preserve every prohibition on Git, gh, network, repository operations, repository-authority creation and unselected heavy hydration. No other pre-Continue child is allowed.

The helper may read only authenticated application resources and the verified host policy inputs required by its contract, consume candidate path text through typed stdin, and return bounded typed classification. It must not open, stat, list, traverse or inspect any candidate. Candidate paths must not enter argv, environment variables, or diagnostic logs. Only an exact validated allow result permits subsequent candidate access. Missing, stale, conflicting or malformed configuration, pending or incorrect release pins, unexpected output, helper failure, cancellation or timeout refuse access.

The catalog module remains independent of Core, process-launch and network implementations. Core supplies a typed batch admission interface, rooted in a coherent policy snapshot. A caller cannot turn a path, origin hint, saved selection, policy digest or previously accepted chooser row into a later operation grant.

### Ordering and bounded work

1. Obtain the effective account from the account database. Authenticate the signed adapter and release contract and independently qualify the explicitly selected interpreter. Ambient PATH lookup, a source checkout, a developer-tool launcher and a permissive fallback cannot establish runtime authority.
2. Load and revalidate the closed host binding, policy projection, policy bytes and pinned installed AWA module. Bind generated configuration to the current deployment-owned source hashes. No concrete deployment literals or copied matcher enter this repository.
3. Classify the governed root before opening it. Classify every subsequently discovered candidate and intermediate path before its first metadata read or open. Listing an admitted parent yields names only; those names confer no access authority.
4. Batch candidate text in bounded groups or use one bounded owned catalog-session transport. Do not start one interpreter per child. Every response must bind the exact request identity, complete ordered candidate list and policy snapshot. Missing, duplicated, reordered or extra decisions refuse the batch. A match produces a visible disabled row from already available lexical or saved display data, without opening that target.
5. Revalidate policy at Continue and every later repository-sensitive admission, including hydration and authority changes. Never reuse chooser classification as mutation authority. A changed snapshot invalidates the selection and requires a fresh chooser or an explicit refusal.

Scratch inputs are private, bounded, unlinked descriptor snapshots with verified ownership and cleanup. They are not persistent repository authority or an operation record. The helper and all owned descendants are subject to existing cancellation, authenticated process identity, deadlines and reaping. No helper survives catalog completion, cancellation, refusal or shutdown.

### Performance and UI behavior

Keep the inherited 750 ms aggregate catalog deadline and the one-second usable-chooser physical acceptance target. Policy setup, classification and cleanup count toward those limits; an individual transport's larger maximum does not extend the catalog deadline. An incomplete or expired catalog is explicitly degraded and cannot enable operations using partial evidence.

Measure the existing twenty-trial first-screen protocol, representative inventories and bounded worst-case synthetic inventories. Record helper count and lifetime, catalog p50/p95/max, time to a usable chooser, candidate access ordering and cleanup. A slow safe refusal is not a passing usable-chooser measurement. A breached target remains an open defect; do not remove timing or process assertions to obtain a passing result.

## Verification and delivery gates

The application engineer owns implementation; the release engineer owns production test-seam and artifact checks; the operator retains native physical-input and UAT acceptance. Independent review precedes source merge.

- Required synthetic tests prove root and intermediate-path rejection before filesystem access, protected saved selections without hydration, stale-snapshot refusal, exact batch response correspondence and no candidate data in process metadata or logs.
- Process tests distinguish the explicitly permitted policy helper from every forbidden child. Poison fixtures, missing policy and timeout/cancellation tests prove zero forbidden work and complete owned-child reaping.
- A source/import/object/link audit keeps process and network implementations out of the catalog module. Production binaries exclude all fixture bypasses and injected admission seams.
- Native timing measures all added work and preserves the first-screen target. Compile checks, source-contract checks and isolated helper tests do not substitute for that measurement.
- Installed qualification still requires the exact externally released AWA runtime, deployed policy/binding, qualified interpreter, signed application and the existing activation gates. No real protected repository is a test fixture.

Historical accepted documents remain immutable. Their zero-child assertions remain valid for the historical builds they describe. Standalone successors update only the process-count assertion and add the helper-specific evidence above; other legacy safety and timing requirements survive. Keep the exact private provenance mapping in the originating documentation authority rather than publishing machine data or private operational evidence.

## Consequences

Pre-Continue behavior now includes one explicitly governed class of child process. This makes the required external classifier visible in the contract and prevents a misleading process-free claim. It adds latency, runtime-trust and cancellation obligations without allowing repository work before the user's selection.

Until the complete admission path and native performance are qualified, the application must refuse unsafe access and the corresponding P5/native acceptance gates remain open. This decision is not installation, release, channel-promotion or UAT approval.
