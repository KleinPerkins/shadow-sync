# ShadowSync

ShadowSync is a proprietary macOS application for inspecting local Git repositories and applying bounded, fast-forward-only updates to authorized worktrees.

## Current status

The standalone application source, resources, fixtures and verification tooling are present. **This source is under qualification and is not install-ready.** There is no qualified signed ShadowSync product release or verified standalone migration yet. The [MVP delivery decision](docs/adr/0008-mvp-first-standalone-delivery.md) prioritizes a signed, safely installed application and working repository CI.

The source uses the permanent identity `shadow-sync` / `com.kleinperkins.shadow-sync`; the product remains **ShadowSync.app**. The target is macOS 26 arm64, with a 26.0 deployment target. Runtime support is claimed only for versions actually qualified; compilation does not establish minimum-version support. Intel and macOS 27 support are not claimed.

The snapshot has fresh public history and [per-file provenance](Resources/source-export.json). Private source history, deployment configuration and user state are excluded. [BOOTSTRAP.md](BOOTSTRAP.md) defines the publication boundary.

## Development

The package requires Swift tools 6.2 or newer and a macOS 26 SDK. The intended hosted release toolchain remains Xcode 26.6; local compilation evidence records the toolchain actually used.

Source and Python tooling checks use disposable fixtures:

```sh
python3 -I -B scripts/verify-source-contract.py
python3 -I -B -m unittest discover -s Tests/Tooling -p 'test_*.py' -v
```

For a local, ad-hoc-signed development bundle, create private scratch and output directories outside the source tree:

```sh
work=$(mktemp -d /private/tmp/shadow-sync-build.XXXXXX)
./scripts/build-app.sh --scratch-path "$work/build" --output-dir "$work/output"
```

This produces a development bundle, not a distribution or an installation. `install.sh` refuses production installation, repair and removal. Do not run historical lifecycle/native scripts against a real home or repository inventory. Runtime and native suites require the reviewed isolated runners; plain `swift test` is a compile/package check and does not execute the substantive runtime suite.

## Verification and delivery gates

The source inventory includes mandatory runtime cases and sharding/evidence validators. Full current-source runtime coverage and hosted application CI are still being qualified. The existing `CI tooling qualification` workflow tests Python tooling only. The privileged reviewer-App workflow is staged with both jobs disabled until full CI provenance, dependency-content policy and exact-head delivery tests pass.

The next product milestone requires Developer ID signing, hardened runtime, notarization, stapling, downloaded-byte verification, deployed policy compatibility, source-free installation and preserved-state migration. Startup remains explicit opt-in through normal macOS Login Items.

Sparkle is not integrated or available in the MVP. Its reserved normal-update authority in the release contract does not mean updates work. Installed-update proof, channel feeds, broader promotion, formal performance tuning and final compatibility retirement remain in the separate post-MVP backlog. Until qualified, no automatic update or source-build replacement path is supported.

## Safety and policy

Repository selection never grants canonical authority. Operations revalidate identity, policy, configuration, refs, worktree claims, cleanliness and process ownership before mutation. Git updates remain fast-forward-only; the extraction introduces no reset, rebase, stash, clean, switch, push, force-update or history-rewrite path.

Generic protection contracts remain owned by [AWA](https://github.com/KleinPerkins/awa). Concrete host-policy values remain outside this repository. Missing, stale or invalid policy fails closed before repository access. The optional external cleanup adapter has no implicit host-tool path; its policy-bound integration remains an activation gate.

Public automation uses disposable repositories and state. Physical desktop acceptance follows the [native acceptance runbook](docs/runbooks/native-acceptance.md). Cancellation, child cleanup, continuous operation locking, migration and recovery require their own execution evidence. Source publication is not product acceptance.

Do not post real repository inventories, credentials, local paths, screenshots or unredacted logs in public issues. Report vulnerabilities through [SECURITY.md](SECURITY.md).

## License

Source is public and proprietary. [LICENSE](LICENSE) reserves rights; public visibility does not grant an open-source license. Third-party assets retain the licenses identified in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Binary-use terms will accompany a qualified distribution.
