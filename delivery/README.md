# Private ShadowSync distribution

This component copies the private delivery and access-file implementation from
[Machine Monitor](https://github.com/KleinPerkins/machine-monitor/tree/f76323e372a239f8da923940808fefeb1e1d9987/delivery), with product-specific identity and
standalone installation gates. Source and synthetic checks establish no provider
deployment, signed release, supported-host qualification or installation.
`PROVENANCE.json` binds the copied source and adaptations.

Public source and GitHub Actions remain separate from private binary delivery.
No binary, access file, account identifier, deployment origin, recipient data or
owner credential belongs in this repository or a public Actions artifact.
The staged candidate-release workflow still requires private-channel adaptation
before it can execute publication; this component does not enable that route.

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

The CLI supports guarded deployment/privacy readback, grant creation/revocation
and immutable qualification publication followed by identical-byte friend-channel
promotion. Every operation retains the copied Free, source/configuration, route,
version and artifact checks. No provider command runs merely by importing source.

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
