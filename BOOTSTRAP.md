# Public foundation and source-import bootstrap

Foundation publication and product-source publication are two independent stages. Do not make the governed empty foundation depend on transformed application bytes or an application build.

## Stage 0 — governed public foundation

The foundation may be published before product source when:

1. only the reviewed generated governance scaffold and target-owned public documents are present;
2. the placeholder README and private-repository security wording are replaced; target-owned instructions retain the reviewed generated governance block;
3. the proprietary source-visible `LICENSE` is present;
4. no private source snapshot, transform receipt, sensitive deployment literal, machine-specific absolute path, secret, log, screenshot, or private history is present;
5. scaffold paths, modes, and hashes are recorded in the private foundation review manifest; and
6. the exact foundation content commit/tree is recorded in the retained bootstrap delivery evidence alongside the helper's existing governance receipts.

Stage 0 validation is document/configuration validation only. It must not invoke or require a ShadowSync build, installer, lifecycle test, live inventory, or private policy adapter.

## Stage 1 — product-source import

The product-source import follows [ADR 0008](docs/adr/0008-mvp-first-standalone-delivery.md): reviewed source publication precedes full runtime and installation qualification. The publication checks below bind one exact target revision; runtime, signing and activation gates remain separate and incomplete until exercised.

### Import boundary

1. Continue from the fresh foundation history; never import or filter private source history into it.
2. Materialize only paths allowed by the privately retained, reviewed extraction manifest from its exact recorded source tree.
3. Preserve recorded regular/executable modes; reject source-export symlinks, submodules, extended-attribute sidecars, and unmanifested files. Packaged frameworks may contain only the separately reviewed, sealed internal symlinks.
4. Apply every declared rewrite or externalization and fail on any undeclared byte difference.
5. Add the reviewed public-foundation files as target-owned files; retain the private review ledger outside this repository.

### Required retrofit

1. Make the repository root the canonical source root.
2. Replace private source-origin, subtree, metadata-lock, and parent-repository assumptions with target-owned source identity and release provenance.
3. Move private shelves, protected repository IDs, governed-root identity, worktree-manager paths, policy paths, and external-manager state into private deployment configuration.
4. Keep production fail-closed when required private policy is unavailable or invalid.
5. Replace private repository identities in tests with synthetic fixtures.
6. Replace private plan, orchestrator, bootstrap, and verifier dependencies with target-local checks.
7. Make public CI fixture-only; live inventory, lifecycle, and screenshot modes remain local and opt-in.
8. Repair the third-party-notice SHA-256 pins to the exact committed notice.

### Product-source validation

- source manifest and output manifest are complete and mutually consistent;
- no private repository, company shelf, helper path, personal name, or private source repository appears outside the private receipt;
- proprietary `LICENSE`, `SECURITY.md`, `AGENTS.md`, `.gitignore`, `.gitattributes`, and asset provenance are present;
- Lucide notice and source pins are retained and bundled;
- a bounded secret scan reports only reviewed synthetic fixtures;
- standalone package compilation and applicable fixture-only source/tooling checks pass; the complete runtime roster remains mandatory before activation, with failures and incomplete coverage explicitly recorded;
- source-attestation tests use the target repository and no private parent files;
- live install remains disabled until its exact standalone lifecycle gates pass;
- the public manifest records imported target paths, regular/executable modes and SHA-256 hashes; external delivery evidence binds the final manifest-bearing commit/tree without a self-referential hash;
- privileged automation imported with source is explicitly reviewed and staged disabled until its CI/protected-content/approval prerequisites pass; dormant code is not operational delivery evidence.

A committed manifest cannot truthfully contain the hash of the same Git tree that contains it. Use either a follow-up provenance commit that names the preceding content commit/tree, or an external attestation that names the final manifest-bearing commit. Never insert a guessed or self-referential hash.

## Delivery rule

Publication is not release or installation. Do not enable a binary release, installer path, or live-host automation merely because the source import merges.
