# Source delivery

Fixture Python failures retain their exception and traceback as single-line,
JSON-escaped `DIAGNOSTIC` records on stderr. Canonical case markers and failure
status remain unchanged. Use these details to diagnose a failed check; a passing
diagnostic workflow does not replace a failed required CI run.

Each bounded Discovery metadata read batches its known lexical paths before
validating the selected directory. Exact path decisions, authority checks,
postflight checks and the original one-second stage deadline remain enforced.
This avoids a redundant serial policy-helper call within the same stage.
Preparation expands lexical prefixes and sends path strings to the hash-qualified
`HardNoTouchMatcher` named by `Resources/awa-contract.json`; that matcher's path
normalizer and classification operate on strings. Authority/resource validation
reads bound policy resources, never candidate metadata. `requireSelected` is the
physical directory-identity boundary before the read body. The metadata regression
covers all eight read kinds and replacement-directory/symlink swaps after rebinding,
requiring refusal before a metadata read while retaining the original deadline.


In fixture `costs` mode, the first two initial inventory metadata callbacks each
emit one bounded `DISCOVERY FIXTURE INVENTORY` summary, even after optional trace
saturation. `counts` are session, publisher and transport calls; `session_ns` are
scratch, host snapshot, resources and postflight intervals; `publisher_ns` are
resource files, executable identity and runtime tree intervals. Nested durations
overlap. `refusal_access` freezes the first refusing access ordinal. These counters
are synchronous testing-only observations, contain no paths or input bytes, and
share the existing 64-record/16-KiB budget with a separately reserved first refusal.
The single original stage deadline and every admission/cleanup check remain intact.
This interval starts after selection rebinding and excludes earlier catalog setup
and outer owned cleanup. It cannot qualify the complete catalog responsiveness or
cleanup requirement. Use it only to attribute cost within the initial metadata
stage; the existing cold-catalog assertion and guardian cleanup evidence remain
separate mandatory checks.

Every ready PR requires fresh automatic independent review from the enrolled PR-creation account. The authoring agent freezes current head/base and trusted enrollment policy, runs `scripts/local_review.py`, fixes findings, then uses `scripts/create_review_pr.py` to create the PR and separate origin witness. Publish the unedited review receipt prefixed with `<!-- g1-review-receipt:v1 -->`. A changed head, base or trusted policy requires new review. Unknown origin or ambiguous creation preserves the private journal and blocks automatic retry; diagnose actual remote state read-only. The operator is not the technical reviewer.

Ordinary local capture and creation require supplied policy bytes to equal the
registry Git blob at the exact request base commit before account/model access and
on frozen-tuple rechecks. Proposed registry changes remain untrusted candidate diff.
Use the admitted base capture and creation helpers, with their existing enrolled
pins, to review and create a PR that changes those helpers or their pins.

For initial owner-admitted source evidence only, `--owner-bootstrap-policy`
explicitly binds the candidate registry instead. This option requires that the
base commit has no registry; ordinary mode refuses a missing base registry without
fallback. It adds no App admission, merge or activation authority. The existing
runtime account check matches ChatGPT email to the owner-declared private
enrollment. Policy-byte binding does not authenticate a private enrollment changed
by a principal with the same local access; that remains Q16's trusted-local limit.

Git-object inspection has stricter operational budgets than the source schema:
5,000,000 bytes of captured output per command, 32,000,000 bytes per generated
file, 30 CPU seconds and 60 wall seconds per command. The schema's 32 MiB per-file
and 256 MiB total source ceilings are validation upper bounds, not guaranteed
inspection capacity. Exceeding an operational budget refuses admission, so an
otherwise valid larger repository can encounter an availability limit.

The successor Reviewer App reads trusted main source, checks enrolled origin and review, exact Actions run/attempt and every canonical unit, strict protections and its repository-scoped identity before App-owned native squash. The frozen ADR0004/0007 remain the native and fixture architecture baseline. The owner-authorized G1 successor extends source admission to independently reviewed automation changes after initial owner/admin bootstrap; it does not authorize a product release. Existing dependency maintenance remains separately governed.

The predecessor App workflow stays disabled. New source does not enable the external `REVIEWER_APP_ENABLED` flag. Initial protected bootstrap, real hosted transition and routine qualification, owner-visible controls, both account origins and read-only current-main App readiness precede writer activation. Keep writer off for read-only `app-current` qualification. Agents never manually merge, arm/cancel auto-merge or bypass checks. Fixture source merge, installation, signing, release and UAT are distinct outcomes.

Source admission is a review and CI gate for source changes, including automation changes after initial owner/admin bootstrap. It is not a permanent path allowlist for future source PRs. The current fixture-CI migration excludes held product work, installation, signing and release changes. A later source merge does not authorize running installation, obtaining signing credentials, publishing a release, changing repository administration or activating the App writer; those operations retain their separate authority gates.

Read-only App qualification reports its selected current-main CI run, actual App
identity and repository token scope, current-token non-bypass proof and observed
controls. The initial writer-activation procedure separately collects and verifies
successful transition and routine execution on the admitted main revision, both
enrolled account origins and the remaining owner-controlled prerequisites before
enabling the writer. Preserve that separate initial evidence. Ordinary
requalification of an unchanged registration validates the current run in its
recomputed required mode; it does not require a new transition on every source
head. The qualification command performs no activation mutation.

Before approval and again before native delivery, the validated repository-scoped App token must report `current_user_can_bypass: never` for every contributing active main ruleset, with complete, nonduplicated ruleset coverage. Read-only App qualification uses the same checks. An absent or unknown caller-specific status blocks delivery. A redacted `bypass_actors` list remains explicitly unknown; a visible list must still match the declared owner exception. The gate re-reads the exact current App approval after submission and immediately before native delivery, refusing a missing, dismissed, duplicated or changed approval.

GitHub documents repository ruleset GETs and effective branch-rule reads with
[Metadata read permission](https://docs.github.com/en/rest/repos/rules#get-a-repository-ruleset).
Administration permission is not required for those reads; `bypass_actors` may
remain redacted without ruleset write access. On 2026-11-17, the selected App's
[actual read-only qualification](https://github.com/KleinPerkins/intent-router/actions/runs/44165228588)
returned caller-specific `never` with a token narrowed to contents and pull-request
read permissions and no Administration permission. That demonstrates API
permission compatibility; ShadowSync's own read-only qualification remains a
separate mandatory gate. Preserve the narrowed token permissions.

`Resources/source-export.json` records transformed product payloads and third-party imports, including their modes and hashes. It is not an inventory of every authored repository file. Update its entries whenever a listed imported payload changes; `verify-source-contract.py` verifies those listed bytes and modes. Newly authored source and CI helpers are bound by the tracked-source digest, exact Git revision and canonical CI registration. Adding an imported payload still requires its provenance entry and applicable review.

The live GitHub GraphQL schema checked on 2026-11-17 exposes `expectedHeadOid` in both `MergePullRequestInput` and `EnablePullRequestAutoMergeInput`. Both native delivery branches intentionally pass that field; dropping it would remove the API's expected-head condition. For API diagnosis, re-read those input fields through authenticated read-only GraphQL introspection rather than assuming an older schema. This schema observation does not establish that delivery or activation occurred.

The trusted-main App derives the expected tracked-source digest from the exact candidate Git tree, blob bytes and executable modes without checking out or executing candidate files. A claimed aggregate digest must match before plan admission. Independent source review of CI changes and GitHub-produced run/check identity remain required. Candidate-produced receipts and logs are operational CI evidence, not independent attestation of honest execution by a malicious author; source binding does not make that stronger claim.
