# Private MVP candidate release

The owner-local release command produces the first private qualification
candidate, version 0.10.0 build 15. The standard CI workflow runs the
release and private delivery contracts as tooling suites with synthetic inputs.
The application repository catalog has its own native responsiveness fixtures.
Source review, hosted CI, artifact qualification, installation, migration and
physical acceptance each require their own evidence.

## Before building

Use an owner-controlled macOS 26 arm64 builder with Xcode 26.6 build 17F113
selected. Install the pinned Node 26.4.0 and Wrangler 4.158.0 independently.
Start in a clean native checkout of the exact merged main commit. Its latest
mandatory push workflow attempt must have a successful bound aggregate.
Pass the destination's exact macOS build. Its arm64 command graphs for launchd
inspection, signature inspection, Git discovery, system Git configuration and
the bundled policy runtime must already be qualified and bound to the release
contract. An empty or incomplete catalog refuses before candidate allocation.

Keep the provider configuration, retained assets and deployment receipt in
owner-private storage outside Git. Use the [configuration
template](../../delivery/owner-config.example.json) and a current,
account-bound Workers Free dashboard observation. Use the original provider
OAuth or an explicit scoped Wrangler token. The command keeps signing inputs
out of provider subprocesses.

Supply the owner GitHub read token as `OWNER_GITHUB_READ_TOKEN` and the
allocation token as `GH_TOKEN` through owner-managed environment settings. The command verifies the human repository
owner, protected main, immutable releases and active no-bypass candidate tag
protection. The tag and asset-free draft reserve the candidate build. The
qualification archive and first-install disk image remain private.

## Produce the candidate

Choose an unused attempt identifier and an unused child of an owner-private
directory beneath physical `/private/tmp`. Keep the attempt records and lock.

```sh
python3 -I -B scripts/release-candidate.py run \
  --source-revision FULL_MERGED_MAIN_SHA \
  --attempt-id UNIQUE_POSITIVE_INTEGER \
  --target-system-build QUALIFIED_DESTINATION_BUILD \
  --work-directory /private/tmp/OWNER_PRIVATE_PARENT/UNUSED_ATTEMPT \
  --delivery-config /OWNER/PRIVATE/delivery.json \
  --credentials /OWNER/PRIVATE/signing.json
```

The owner-owned mode-0600 credentials JSON has eight keys. Set
`APPLE_CERTIFICATE` to the base64-encoded PKCS#12 certificate and supply
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
`APPLE_PASSWORD`, `APPLE_TEAM_ID`, `SPARKLE_PRIVATE_ED_KEY` and
`SPARKLE_PUBLIC_ED_KEY`. Keep the values on the signing host.
`--help` lists the required command arguments. Choose `prepare`, `sign`,
`publish` or `cleanup` when running a single stage. Only `run` and `sign`
accept the credentials file.

The command Developer ID signs the application, lifecycle coordinator and
bundled runtime, notarizes and staples the app and disk image, checks Gatekeeper
and verifies detached signatures. Private authenticated readback verifies both
artifacts before the qualification pointer can advance. The command checks
release authority again immediately before that write. The private route
identifier uses hyphens in place of the public tag version's dots.

## Recover a stopped attempt

Durable allocation, signing and publication intents mark attempted side effects.
Keep those intents, accepted notarization IDs and the exact bytes they reference.
An interrupted provider request can have succeeded. Reconcile the recorded
identity before any further write, using the owner-operated service and the
recorded attempt. The notarization helper's resume path requires recorded
submission IDs and exact retained inputs. Keep raw details, credentials,
grants, binaries and private service configuration in owner-private storage.

Confirm downloaded signatures, publisher and notarization on the destination
Mac before signed coordinator acceptance. Use disposable repositories for
selection, fast-forward, refusal and rollback checks. Verify that the legacy
writer is stopped before switching the live installation. The private
qualification channel does not enable stable distribution or automatic updates.
