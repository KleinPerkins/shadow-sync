---
{"approval":{"actor":"Codex under owner-delegated execution authority and the accepted safety-release exception; not an assertion of operator hash inspection","date":"2026-11-02","review_sha256":"2e695711a9112680faa1f688b6a69c8f381c3f82b9c5554c51db179b1073c843"},"authority":"semantic","github_repository_id":1442961455,"id":"ADR-29e9090a-7b77-443d-b953-9b1deef3bc60-b02628d1-fbf8-5bba-87fe-689396ffd9b0","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"29e9090a-7b77-443d-b953-9b1deef3bc60","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# ADR 0005: Governed safety release without controller rebinding

## Context

The accepted standalone requirements and execution plan made deployed controller
maintenance-base support a prerequisite for the AWA v1.8.2 safety release.
The AWA owner has selected a one-time audited release-administration route for
the exact hard-no-touch backport instead. ShadowSync must consume the resulting
verified release without treating a new controller deployment as product safety.

## Decision

For this one AWA v1.8.2 prerequisite, accept the owner-governed procedure in
[AWA ADR 0031](https://github.com/KleinPerkins/awa/blob/main/docs/adr/0031-one-time-administrator-release-route-for-awa-v1-8-2.md)
once that authority is merged and its release gates are evidenced. Require the
reviewed source/base/head/merge/tree chain, complete verification, independent
technical review, effective branch protection, audited administrator merge,
sealed maintenance branch and immutable release identity. Do not label these
receipts as controller verification or App approval.

This narrowly supersedes the controller-deployment dependency in REQ-SF-03 and
phase P4. Publish corresponding PRD and plan successors with the same stable
requirement IDs. Preserve accepted predecessors byte-for-byte. No other product
requirement, delivery model, support target or acceptance criterion changes.

The controller and fleet bindings remain unchanged. ShadowSync continues to use
its own native GitHub Actions/reviewer-App process under ADR 0004; its PR tests
do not move to the fleet controller.

Before installed activation, still require the exact released AWA version and
module identity, governed runtime binding/install, concrete host policy and
compatibility binding, verified pre-access consumer, signed lifecycle/migration
qualification and explicit product acceptance gates. Fail closed on missing or
incompatible evidence. Never copy the matcher, weaken host policy, reactivate an
unsafe legacy host or substitute a locally built candidate for the release.

Only sanitized release and contract references belong in this public repository.
Keep host configuration, concrete protected targets, fleet inventories, private
verification logs and administration receipts with their owning repositories or
private evidence store. A linked authority is not proof that its steps completed.

## Consequences

This removes a fleet-wide controller deployment from one safety-release dependency
without reducing the product's policy or runtime qualification gates. A future
release route or additional maintenance patch requires its own owning authority;
this record is not standing permission for administrative product merges.
