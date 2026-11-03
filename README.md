# ShadowSync

ShadowSync is a proprietary macOS application for inspecting local Git repositories and applying bounded, fast-forward-only updates to authorized worktrees.

## Repository status

This repository begins as a governed public foundation. It contains repository policy and planning scaffolding; application source, builds, installers, and releases are not yet available here.

The product source will be imported from a reviewed snapshot with per-file provenance. Private Git history, host configuration, user state, and unrelated source are excluded. [BOOTSTRAP.md](BOOTSTRAP.md) defines the source-import and publication gates.

## Planned standalone delivery

- Product: **ShadowSync**, distributed as **ShadowSync.app**.
- Technical identity: `shadow-sync` / `com.kleinperkins.shadow-sync`.
- Initial support: **macOS 26, arm64**; minimum deployment target 26.0. Intel and macOS 27 support are not claimed.
- Build baseline: Swift tools minimum 6.2, Xcode 26.6 and its bundled toolchain.
- Distribution: Developer ID signed and notarized application, with verified Sparkle updates after installation and update qualification.
- Startup: explicit opt-in through normal macOS Login Items behavior.

These are delivery requirements, not claims that a signed release or installed migration has already passed.

## Safety and policy

Repository selection does not grant canonical authority. Operations must revalidate repository identity, policy, configuration, refs, worktree claims, cleanliness, and process ownership before mutation. Git updates remain fast-forward-only; no reset, rebase, stash, clean, switch, push, force-update, or history rewrite is added.

Generic protection contracts remain owned by [AWA](https://github.com/KleinPerkins/awa). Concrete host-policy values remain outside this public repository. Required policy must be present, compatible, and verified before repository access; missing or invalid policy fails closed.

Public automation uses disposable repositories and state. Native desktop acceptance, installed migration, signed updates, and recovery are separate verification milestones. Foundation publication does not authorize running source-bound installation or live-inventory tools.

## Development and reporting

Build and test instructions will accompany the source import. No build command is available in this foundation.

Do not post real repository inventories, credentials, local paths, screenshots, or unredacted logs in public issues. Report vulnerabilities through the private process in [SECURITY.md](SECURITY.md).

## Native acceptance

Physical desktop acceptance remains open and follows the [native acceptance runbook](docs/runbooks/native-acceptance.md). Its disposable-fixture scenario names the first selected clone `00-dirty-first`, makes it dirty after review, and requires execution-time revalidation to report it as `SKIPPED_DIRTY` without mutation. Cancellation, child cleanup, keyboard/VoiceOver behavior, installation and updates retain their separate evidence gates.

## License

Repository contents are public and proprietary; application source is not yet present. See [LICENSE](LICENSE) for reserved rights; public visibility does not grant an open-source license. Third-party assets and libraries retain their own identified licenses when imported. Binary-use terms will accompany any qualified distribution.
