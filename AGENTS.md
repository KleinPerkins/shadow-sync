# Agent instructions

## Repository boundary

This is a public, proprietary source repository. Treat every committed byte, issue, pull request, check log, and generated artifact as publicly disclosed.

Do not introduce real usernames, home paths, machine identifiers, repository inventories, commit or branch details from unrelated private work, credentials, logs, screenshots, retained artifacts, or private host configuration.

The initial repository may be a governance-only foundation with no product source. Do not infer source availability, buildability, release, installation, or deployment from foundation publication.

## Private deployment policy

Private shelf names, protected repository identities, governed-root ownership, worktree-manager executables, policy file paths, and optional external-manager state schemas belong to deployment configuration outside this repository.

- Do not hard-code organization-private repository names or company directory layouts.
- Do not weaken or delete protections when externalizing them.
- Production must fail closed when required policy is absent, malformed, stale, or unverifiable.
- Tests use `fixture-owner/*`, `owner/*`, reserved domains, and temporary roots only.

Legacy identifiers are allowed only in file-specific, token-specific migration readers, compatibility fixtures, and historical evidence. Active identity is `shadow-sync` / `com.kleinperkins.shadow-sync`. Legacy installation readers have the accepted two-release/90-day minimum compatibility window and an explicit retirement receipt; historical data readers may remain without launching or writing the legacy identity.

Repository names in legitimate public policy or provenance links are not secrets. Preserve canonical links to the public [AWA host-overlay decision](https://github.com/KleinPerkins/awa/blob/main/docs/adr/0002-awa-dev-overlay.md) and [AWA integrity lifecycle decision](https://github.com/KleinPerkins/awa/blob/main/docs/adr/0020-awa-integrity-surveillance-and-lifecycle.md). Keep deployment values and host literals in private authority rather than duplicating them here.

## Source and provenance

- The repository root is the source root; do not assume a parent capability repository.
- Foundation creation is independent of private product-source transformation or application builds.
- When product source is present, keep the public export manifest current when a transformed or third-party file changes.
- Preserve executable modes and reject symlinks or submodules in exported source; bundled frameworks may contain only the reviewed sealed internal symlinks.
- When third-party or product asset bytes are present, retain `THIRD_PARTY_NOTICES.md` in source and built bundles.
- When Lucide-derived assets are present, preserve the pinned source, license, and asset hashes or update them through an explicit provenance review.
- Do not import raw private Git history, plans, ADRs, runbooks, registry data, automation, or unrelated commit metadata. Sanitized derived provenance is separately reviewed.

## Safety invariants

- Git updates remain fast-forward-only; do not add reset, pull, rebase, stash, clean, checkout, switch, push, force-update, or history-rewrite paths.
- Repository selection never grants canonical authority.
- Revalidate identity, policy, config, refs, claims, cleanliness, and process ownership immediately before mutation and in postflight.
- Never bypass hooks, verification, signing, or source-attestation checks.
- Do not run install, repair, uninstall, live inventory, lifecycle, or screenshot automation without explicit local intent and a verified standalone source contract.

## Tests and fixtures

Public automation is fixture-only. It must not read the host's real governed root, installed ShadowSync state, user Git config, credentials, or screenshots.

Secret-shaped strings are permitted only in redaction tests. Generate or narrowly annotate them so scanners do not confuse them with live credentials; never use a real secret as a fixture.

Use fresh owner-private temporary roots. Clean up only resources created by the current test after validating their identity. Never use broad or unresolved destructive paths.

## Documentation and claims

Document current behavior, not private delivery history, operator conversations, UAT receipts, or unpublished topology. Distinguish source build, installation, merge, release, and deployment; do not imply one proves another.

Do not claim the public foundation is install-ready until standalone source identity, private policy injection, fixture-only public validation, notice integrity, and proprietary licensing all pass at the exact published revision.

<!-- doc-warden:begin -->
## Documentation governance

| Artifact type | Location |
|---|---|
| Project, roadmap, and state | `.planning/` |
| Phase plans | `.planning/phases/` |
| ADRs | `docs/adr/` |
| Runbooks | `docs/runbooks/` |

**Policy:** `~/dev/_ops/doc-warden/POLICY.md`
**Engine:** `~/dev/_ops/bin/doc-warden.sh doctor repo --repo .`
<!-- doc-warden:end -->
