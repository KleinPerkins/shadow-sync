# Private MVP candidate automation

Status: source implementation under qualification. A successful synthetic test or source workflow is not a signed release, deployment, installation, migration or operator acceptance.

## Execution boundary

The `Private release source contracts` workflow runs synthetic orchestration checks on trusted main. It has read-only repository permission, no credentials and no artifact upload. Mandatory application CI remains the source qualification gate. Product signing and private publication run through the explicit owner-local `scripts/release-candidate.py` command, following the owner-local private delivery pattern. This preserves the existing private retained assets, deployment receipt and original Wrangler authentication rather than reconstructing them in a public hosted job. Self-hosted Actions are not supported.

The command builds the exact current merged main after its latest mandatory CI attempt succeeds, reserves version `0.10.0` build `15`, assembles and Developer ID signs the source-free application and lifecycle coordinator, notarizes and staples the app and DMG, creates an archive of the final stapled app, independently verifies detached signatures for both artifacts, removes temporary Apple credentials, and calls the existing private qualification publisher. Authentication-protected downloaded-byte verification precedes qualification-channel advancement. Neither artifact is uploaded to GitHub Releases or Actions.

The public candidate tag and asset-free draft are allocation markers. They remain reserved on success or failure; the draft is never converted into a public binary release. The private immutable qualification manifest is the distribution record. Stable/friend promotion, updater activation, installation and acceptance are separate operations.

## Explicit inputs

Run only from a verified clean native workspace at the intended main revision with the accepted macOS 26 arm64 and Xcode 26.6 toolchain. Set `DEVELOPER_DIR` to the accepted Xcode developer directory. Pinned Node 26.4.0 and Wrangler 4.158.0 must already be available; the command does not install provider tools or change authentication.

Supply the existing owner-owned mode-0600 delivery configuration outside Git. Its schema remains [owner-config.example.json](../../delivery/owner-config.example.json). Retain the mode-0700 private asset directory and the actual deployment receipt. Account, origin, resource names and paths are deployment inputs, never source defaults. The referenced Workers Free observation must bind the configured account, originate from a real owner dashboard observation, and expire at most one hour after observation. An absent, stale, wrong-account or paid observation refuses before provider effects. The command never creates or refreshes this evidence.

`OWNER_GITHUB_READ_TOKEN` explicitly supplies the owner's read capability. Live responses must identify the human repository owner, repository administration visibility, immutable releases, strict effective main controls, and active no-bypass candidate-tag update/deletion protection. The reviewer App is not used or granted additional permissions. `GH_TOKEN` supplies the same verified human owner's allocation capability; its only supported mutations are tag and asset-free draft creation. Tokens never enter child command environments or receipts.

The environment is closed before path, config and credential-file validation as well as signing and publication. Child helpers retain only `HOME`, `PATH`, `TMPDIR`, `DEVELOPER_DIR`, `LANG`, `LC_ALL`, and the explicit `SHADOW_SYNC_DELIVERY_NODE` selection; the signing command runner keeps its narrower six-key allowlist. GitHub tokens, unrelated credentials and interpreter controls such as `NODE_OPTIONS` are excluded. The original private `HOME` preserves Wrangler OAuth. An explicit `CLOUDFLARE_API_TOKEN` is passed only to the pinned Wrangler subprocess, including its authentication read; Git, Node validation and signing never inherit it. Other provider authentication environment overrides are unsupported by this command.

The `--credentials` file is an owner-owned mode-0600 JSON file outside Git with exactly the eight existing release keys: `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`, `SPARKLE_PRIVATE_ED_KEY`, and `SPARKLE_PUBLIC_ED_KEY`. The certificate is base64 PKCS#12, the signing identity is Developer ID Application for the source-pinned publisher, and the detached keys retain the existing pinned public-key hash. Secrets are loaded only for signing, removed from the orchestration environment before publication, and never forwarded as arbitrary subprocess environment. The detached private key reaches the pinned standalone signing utility through stdin; using that utility does not integrate or enable Sparkle updates. The explicitly supplied credential file remains owner-managed.

Create a fresh owner-private parent under `/private/tmp`; select a previously unused child path and opaque positive numeric attempt identifier. The parent and durable attempt lock remain private. Keep all attempt records and recovery evidence outside Git and public artifacts.

```sh
python3 -I -B scripts/release-candidate.py run \
  --source-revision FULL_MERGED_MAIN_SHA \
  --attempt-id UNIQUE_POSITIVE_INTEGER \
  --work-directory /private/tmp/OWNER_PRIVATE_PARENT/UNUSED_ATTEMPT \
  --delivery-config /OWNER/PRIVATE/delivery.json \
  --credentials /OWNER/PRIVATE/signing.json
```

This is the product release automation command; the public workflow is only its source-contract test. The same command supports explicit `prepare`, `sign`, `publish` and `cleanup` stages with the identical revision, attempt and directory. Only `run` and `sign` accept `--credentials`. If the Free observation expires during compilation/notarization, publication refuses; obtain a new real observation before an unstarted `publish` stage. Changing the delivery configuration file after preparation refuses.

## Failure and reconciliation

Exclusive allocation, signing and publication intents prohibit blind reruns. An ambiguous GitHub allocation keeps the tag/draft reserved. An Apple submission is never resubmitted when its ID was not recorded. The existing `notarize-release-bundle.py --resume` interface continues to support only recorded submissions and exact retained bytes; a failed candidate `sign` stage is not an automatic resume route. Retain its signing/assembly/notary records for explicit owner reconciliation, using the existing isolated-keychain and notarization interfaces. Do not delete allocation or intent records to make an attempt appear new.

Each exclusive intent file and its containing directory are synced before the corresponding external effect, including before provider-client construction. A creation or sync failure refuses the stage; any created intent stays in place and prevents a retry. An identical input record alone never authorizes replay.

A provider timeout may mean a write succeeded. The candidate command records publication intent before constructing the provider client and refuses a second invocation. Reconcile exact immutable manifest/artifact/config identities using the existing delivery interface; do not replace bytes or invent a new build identity. Readback, credential cleanup, route/privacy, config or final source/CI failure leaves publication incomplete. The narrow delivery callback repeats source, latest CI, owner controls, allocation and private config verification immediately before channel advancement. It cannot promise atomicity across GitHub and Cloudflare, so a changed final postflight is reported incomplete even if a private channel write succeeded.

Raw notary logs, local paths, credentials, account configuration, manifests, access grants, downloaded binaries and private receipts stay in owner-private storage. The command prints only fixed stage status. Preserve temporary attempt storage before a machine reboot; this source does not provide an automatic archival or transfer service.

## Acceptance still required

Live owner controls, current account-bound Workers Free proof, pinned tool availability, real signing/notarization, exact private deployment and authenticated readback must be exercised at the final published source. Then qualify supported macOS versions, clean installation, failure recovery and preserved-state migration and obtain explicit focused operator acceptance. Source, signing, private publication and installation remain separate claims.
