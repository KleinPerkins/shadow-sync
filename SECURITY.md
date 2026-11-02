# Security policy

## Supported source

Security fixes are evaluated against the current `main` branch. The repository does not promise support for historical commits, locally modified builds, or unofficial distributions.

The initial public foundation contains no product source or binary. A later source import is not approved for live installation until its standalone source-attestation and private host-policy retrofit is complete.

## Report a vulnerability privately

Use GitHub Private Vulnerability Reporting for this repository. Do not open a public issue for a suspected vulnerability, credential, private repository identity, local path, or unredacted log. If private reporting is unavailable, contact the repository owner through an established private channel and include only the minimum information needed to reproduce the issue.

Include:

- affected commit and macOS version;
- the smallest fixture-only reproduction;
- expected and observed behavior;
- security impact and preconditions; and
- whether local Git, `gh`, launchd, signing, lifecycle state, or repository mutation is involved.

Do not include real access tokens, SSH keys, Git config, repository inventories, branch names, commit identifiers, usernames, home paths, screenshots, run logs, or retained artifacts. Replace them with synthetic values.

## Scope

High-impact areas include:

- repository identity and canonical-authority validation;
- command, argument, environment, hook, helper, filter, and config containment;
- ref and worktree claim races;
- cancellation, process ownership, socket, lock, and launchd validation;
- log redaction and private-state permissions;
- install, repair, rollback, doctor, and uninstall path integrity; and
- source, bundle, artwork, and release provenance.

Distributed applications require verified Developer ID signing and notarization. Development ad-hoc signatures are fixture/local-build integrity checks only and do not establish publisher identity. A malicious process with equivalent account privileges remains outside the ordinary local-integrity guarantee.

## Testing rules

- Public CI is fixture-only and network-denied unless a test explicitly documents a bounded public dependency.
- Tests must not inspect the runner's real governed root, installed app, Git config, credentials, or local state.
- Synthetic secret-shaped fixtures are permitted only for redaction tests and must be unmistakably generated or annotated.
- Never test destructive behavior against a real working repository.
- Do not publish native smoke screenshots or diagnostics without a separate disclosure review.

## Disclosure

Please allow the maintainer a reasonable period to investigate and prepare a fix before public disclosure. Do not access data or repositories beyond those you own or are explicitly authorized to test.
