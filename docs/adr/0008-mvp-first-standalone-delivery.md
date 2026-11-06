---
{"approval":{"actor":"Codex under explicit owner-delegated execution authority and MVP-first reprioritization; independent scope review, not product or physical UAT acceptance","date":"2026-11-05","review_sha256":"41f58568880e29c0cf7d999220a4578d03527eb69dd06ca60aa0ea76bb71f1ef"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-6e1c3b1a-6b2e-58ff-9ed9-44d559d8940f","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# MVP-first standalone delivery

The next deliverable is a usable, signed standalone ShadowSync installation and its governed source repository. This decision changes delivery order and milestone scope; it does not declare any previous requirement complete. All frozen predecessors and private evidence remain preserved.

## MVP boundary

Keep the existing repository discovery, selection, preview, safe synchronization, cancellation, reporting and retention behavior. Keep the complete new identity, public proprietary repository, macOS 26 arm64 boundary, source-free signed lifecycle coordinator, and opt-in startup. No UI redesign, new feature, generic execution framework, platform expansion or controller/fleet change enters the MVP.

MVP completion requires reviewed public application source and provenance; working mandatory sharded Actions CI and approved reviewer-App delivery; deployed external policy compatibility; a Developer ID signed, hardened, notarized, stapled immutable candidate; downloaded-byte verification; clean installation; preserved-state legacy migration with one effective operation lock and no overlapping host; failure recovery; and explicit focused native/operator acceptance. Product release, installation and acceptance keep separate evidence. A build, documentation merge or credential check proves none of the later milestones.

The first candidate remains 0.10.0 build 15 if still unallocated. It may be published as a non-Latest pilot release. Supported behavior is limited to the macOS 26 arm64 versions actually qualified. A26.0 deployment target does not prove 26.0 runtime support. Minimum-point-release qualification and broad stable promotion remain open until exercised.

## Work deferred to the post-MVP session

| Deferred outcome | Requirement boundary and owner | Exit gate |
|---|---|---|
| Sparkle integration and installed 15-to-16 proof | MG-05, update portion of MG-01/RL-02 and RL-04; release engineer and macOS architect | Coordinator-gated signature-verified installed update, fault/retry/recovery evidence. Reserve build 16 only after allocation check; no build reuse. |
| Beta/stable feed automation and broad Latest promotion | RL-04 and promotion portion of RL-05; release engineer | Identical immutable-byte promotion after installed-update and supported-platform qualification. |
| Formal 20-trial performance campaign and shard tuning | P5-TRUST-02 performance campaign and GV-10 optimization; application/release engineers | Existing deadline and cleanup behavior remain enforced; measured results and comparisons are required before performance claims. |
| Broader point-release qualification | RL-01 minimum-version evidence; release engineer/operator | Native evidence on 26.0 and other claimed versions; no unsupported claim in MVP. |
| Final compatibility retirement | MG-08; release and source-integration owners | At least two verified standalone releases, 90 days, known-installation review and separate retirement receipt. Retained archives cannot execute the old identity. |

Sparkle is disabled and not advertised in the MVP. The existing signed DMG/coordinator supplies installation and recovery; no source-build updater or second update authority is introduced. Until the post-MVP update qualification is complete, do not promise automatic updates or replace the app by an unqualified path. Existing keys and completed updater work are preserved for that follow-up.

MG-08 retention starts and continues normally. Its 90-day wait does not block MVP availability, and MVP acceptance cannot waive it. Source-installer closure and removal of active legacy launch routes remain mandatory before the new host operates.

## Unchanged safety and verification floor

All EX requirements; GV-01 through GV-09 andGV-11; SF-01 through SF-08; MG-02/03/04/06/07; and release signing/traceability remain required for the relevant MVP delivery stage. For MG-01, all reachable MVP installation, migration, repair and lifecycle routes use the signed coordinator. Startup remains explicit opt-in. Missing/stale policy fails closed before repository access. Preserve selections, canonical authority, logs, recoverable data, continuous locking and stopped legacy rollback.

Reuse the existing custody and fixture designs; complete defects on reachable MVP paths, rather than designing a further generalized framework. No current test, assertion or failure is relabeled optional merely to obtain green CI. Preserve the mandatory suite inventory and aggregate checks for missing, skipped, cancelled, failed, zero-case and incomplete results. Batch the remaining fixture adaptations, use affected tests during development, then execute the complete final-source mandatory roster and hosted shard/unsharded transition qualification. Older-source passes are not combined.

## Separate publication from activation

Reviewed sanitized application source may be published before full runtime, signed-release or installation qualification. Publication requires the exact allowlisted export, provenance/license/identity/privacy checks, independent review, and applicable repository checks. The repository must prominently say that the source is under qualification and not install-ready; installer and release routes remain gated. A source PR can expose outstanding CI failures; it cannot bypass a required failing check or claim qualification.

This prospectively replaces only the blanket private-until-full-runtime wording in the fixture component and the sequence that placed all update/promotion work ahead of first installation. It does not weaken the export review or any activation safety gate. Protected bootstrap changes use their existing administration route; ordinary implementation uses the reviewer App once configured. No synthetic checks, auto-merge manipulation or controller rebinding.

## Execution order and stop rules

1. Publish the reviewed source snapshot and source-owned checks as an explicit pre-release baseline. Establish repository controls and hosted execution now; do not wait for Sparkle or benchmark completion. Architect/release engineer own this step.
2. Complete the remaining reachable production/lifecycle defects and batch the known fixture adaptations on one candidate. Run targeted checks during repair and one complete exact-source qualification at integration. Application architect owns overlapping source and lock changes.
3. Finish signed packaging and deployed safety prerequisites, qualify the signed coordinator against disposable migration/failure fixtures, and produce the first immutable candidate. Release engineer and external policy owners supply exact evidence.
4. Perform the authorized local migration, clean-install/recovery checks and focused physical acceptance. User data and old recovery archives remain preserved. The operator explicitly accepts the MVP; do not infer acceptance.
5. Checkpoint a separate post-MVP backlog with exact source/evidence and the deferred gates above. Do not start that secondary effort automatically before MVP delivery or use it as a reason to delay installation.

Work is measured by deliverables: public source, operational CI, signed artifact, working migrated installation. Routine test observations are consolidated into milestone records, not separate delivery PRs. A new abstraction or safety-contract expansion requires a concrete defect on a reachable MVP path and an explicit material-scope decision. After two unsuccessful attempts without new evidence, stop broad reruns and use a bounded diagnostic or surface the exact blocker. No additional implementation plan is required to begin the first source-delivery step after this amendment is adopted.
