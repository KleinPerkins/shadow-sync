# Private ShadowSync distribution

This component copies the private delivery and access-file implementation from
[Machine Monitor](https://github.com/KleinPerkins/machine-monitor/tree/f76323e372a239f8da923940808fefeb1e1d9987/delivery), with product-specific identity and
standalone installation gates. Source and synthetic checks establish no provider
deployment, signed release, supported-host qualification or installation.
`PROVENANCE.json` binds the copied source and adaptations.

Public source and GitHub Actions remain separate from private binary delivery.
No binary, access file, account identifier, deployment origin, recipient data or
owner credential belongs in this repository or a public Actions artifact.
The public release workflow verifies synthetic source contracts only. The explicit
[owner-local release command](../docs/runbooks/private-release.md) composes the
existing signing, notarization and private qualification publisher. Its source
implementation establishes no live publication or acceptance.

## Delivery and access

The only public routes are `/` and `/download.js`. The browser accepts a private
`.shadow-sync-access` file of at most 4096 bytes with exactly `schema`, `app_id`,
`origin` and `token`. The closed schema is `shadow-sync/access/v1`; the application
identity is `com.kleinperkins.shadow-sync`. Its origin must match the current site.
The random 256-bit token is sent only in an Authorization bearer header. Reset and
page dismissal abort requests and release the browser references. No cookie,
local/session storage, analytics, third-party script or service worker is used.
This does not claim secure memory erasure.

Owner tooling stores only a SHA256 token hash, an opaque label, finite expiry,
revocation state and app/channel entitlements in D1. Qualification access requires
an owner grant plus an explicit qualification entitlement. Owner status alone
does not grant friend-channel access. Revocation blocks subsequent requests and
cannot retract bytes already downloaded or in flight. The owner shares access
files privately; the tool sends no messages.

Every protected request begins a fresh first-primary D1 session and authorizes in
its first query before fetching any private asset. Release rows and ordered part
metadata are append-only. All protected responses are private/no-store. There is
no public object URL, generic asset fallback, Cache API, redirect, CORS, range or
conditional-request bypass. Database, storage, metadata and quota errors refuse.
The supported origin is the exact account-owned workers.dev hostname. Custom
routes, preview/default aliases and unrecognized active versions refuse.

Archives and first-install packages are bound by exact release identity, full
SHA256/size and detached signature descriptors. Ordered pieces are 256 KiB with
closed, bounded metadata; both the browser and owner readback verify pieces and
the complete artifact. Owner publication retains every prior immutable asset,
deploys the complete set before release metadata, and requires authenticated
readback before advancing a channel. There is no retention deletion command.

The browser downloads the first-install package and points to its included signed
installation instructions. ShadowSync installation and recovery retain the signed
lifecycle coordinator. This component adds no native updater, Recovery app,
source-build installer or automatic updates. The macOS 26.0 metadata field is a
build deployment target; supported runtime versions require separate evidence.

## Qualification and owner operations

`scripts/delivery.py` is import-safe. Use the explicit owner-owned mode 0600 config
outside Git shown by `owner-config.example.json`; private asset directories must
be mode 0700 and retained part files mode 0600. Provider mutations require a fresh,
account-bound Workers Free owner observation with provenance and expiry no later
than one hour after observation. Unknown, expired, paid or wrong-account proof
refuses. There is no paid fallback, plan activation, R2 subscription or
`--assume-free` bypass. Resource bootstrap requires separate owner authority.

The implementation retains Node 26.4.0 and Wrangler 4.158.0 pins. Provider tooling
binds the verified absolute Node executable and captures Wrangler authentication
in process memory. Credentials never enter argv, public config, recipient files
or output. Synthetic checks use `scripts/delivery-toolchain.py` with an explicit
task-owned temporary cache; no global runtime installation is performed.

Qualification requires exact-source mandatory CI and merge, Developer ID signing,
notarization, stapling, Gatekeeper, detached archive signature verification and
packaged lifecycle coordinator evidence. Friend-channel publication additionally
requires exact-artifact clean installation, failure recovery, preserved-state
migration and explicit operator acceptance. A JSON assertion alone proves none
of these outcomes. Sparkle installed-update proof and feed/Latest promotion remain
separate post-MVP work.

The CLI supports guarded deployment/privacy readback, access lifecycle commands
and immutable qualification publication followed by identical-byte friend-channel
promotion. Every operation retains the copied Free, source/configuration, route,
version and artifact checks. No provider command runs merely by importing source.

### Owner access lifecycle

Run `python3 scripts/delivery.py --config /absolute/private/config.json COMMAND`.
The config remains owner-private and outside Git. Create a separate owner-owned
mode-0700 directory for access files; the CLI creates mode-0600 regular files
exclusively, refuses symlinks/hard links, and never overwrites an existing file.
All labels must be opaque non-personal identifiers. Tokens and hashes are omitted
from command output. These commands send no messages or email.

| Command | Required arguments and behavior |
| --- | --- |
| `create-grant` | `--label`, `--output`, `--expires-at` (finite future Unix seconds); defaults to non-owner `stable` access. |
| `list-grants` | Lists this application's grant IDs, original channel/owner flag, expiry, revocation and observed state. |
| `grant-status` | `--grant-id`; an empty result means no entitlement for this application was observed. |
| `expire-grant` | `--grant-id --expires-at`; shortens expiry only. A past positive timestamp expires access now. |
| `revoke-grant` | `--grant-id`; denies future authorization without deleting credentials or downloaded bytes. |
| `replace-grant` | `--grant-id --label --output --expires-at`; creates a new private file and grant, verifies them, then revokes the original. Expiry cannot exceed the original. |
| `recover-grant` | `--attempt`; observes retained custody and actual D1 state. Add `--complete` explicitly to perform only never-attempted remaining steps. |

Creation accepts `--channel qualification --owner` only for owner access. For
expiry, revocation and replacement, supply the original `--channel` and `--owner`
flag. These commands require exactly one entitlement for this application and
channel. Foreign-app, extra-entitlement, changed-owner and widened-expiry cases
refuse; a list may report `scope-conflict` for such a grant.

Creation durably retains the access file before any provider write and binds its
exact filesystem identity, token digest, provider resource identity, finite grant
and optional original grant in `OUTPUT.attempt.json`. Retain that private sidecar
and its immutable `.grant`, `.entitlement` and `.revoke` write-intent markers with
the access file. Share only the access file with the intended recipient after the
command reports complete. The sidecar contains private resource metadata and is
owner-only. Do not move, replace, edit or delete these records to force a retry.
The command serializes recovery for one retained attempt using a local file lock;
all independent grant mutations must still have one owner. Before reporting
completion, one final database observation checks the exact new grant and sole
application/channel entitlement together with the original grant's exact identity,
scope and confirmed revocation for a replacement. Recovery then rechecks the
original private access, attempt and observed write-intent marker bytes, modes,
named inodes and held attempt lock. Marker presence is retained for the whole
recovery: a marker that disappears never becomes permission to retry its write.
An unexpected new marker, changed marker, or replacement during exclusive marker
creation refuses completion before the next provider write. Only failure to open a marker
inside an unchanged private parent counts as initial absence. A marker that
disappears after its descriptor is acquired causes refusal, never a new attempt. Observed changes
refuse completion, including changes that preserve parsed JSON but alter stored
bytes. These bounded observations do not make the remote
database and local filesystem atomic or prevent a later independent owner action.

Recovery checks actual D1 and local file state. If a response was lost but the
exact effect is visible, explicit completion can advance the next untouched
step. If an attempted write has no visible effect, recovery returns `pending`
(exit 2) and never replays that request. Preserve evidence and reconcile the
provider's outcome privately before any separate operator action; this tool has
no forced replay or intent-deletion escape hatch. Missing/malformed files,
changed identities and altered scope refuse. An access file left by a failure
before sidecar creation has caused no provider write; preserve it and use a new
output path for a separately authorized creation. Partial sidecars/markers are
retained and require private diagnosis. Never share a pending file.

Replacement leaves the original file untouched. Its old grant is revoked only
after the new finite grant, entitlement and file are verified. An interruption
may temporarily leave both grants active; recovery reports pending until the
old revocation is confirmed. Expired replacement access cannot trigger old-grant
revocation. Expiry/revoke are single conditional scoped writes with readback; if
transport or postflight fails, inspect `grant-status` before issuing another
operation. An already-revoked grant returns its observed state without another
write. Missing entitlement is distinct from an unavailable/denied provider read,
which reports failure rather than inferring revocation. Read-only inspection
never changes a grant. Provider API calls retain
the existing fresh account-bound Free-proof requirement.

Revocation and expiry cannot retract previously downloaded or in-flight bytes.
No source test establishes provider deployment, recipient acceptance, release,
installation, or that an access file was privately delivered to a person.

[Workers Free limits](https://developers.cloudflare.com/workers/platform/limits/)
and [Static Assets billing](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)
remain provider constraints, not guarantees from local tests. Unconditional
worker-first routing counts protected requests against Worker limits and fails
closed on exhaustion. Live CPU, memory, request/D1/storage capacity, route and
privacy qualification are required for the actual account and deployment.

## Explicit post-MVP deliverable

`POST-MVP-SHARED-DELIVERY-ACCESS`: consolidate copied application delivery channels
and access management into a shared tool. It must provide application-scoped
immutable releases, grant issuance/expiry/revocation and entitlements; migrate
existing valid grants and artifacts without loss; and qualify shared Free-tier
capacity, privacy, activation and rollback. Consolidation is incomplete and is
not part of this MVP implementation.
