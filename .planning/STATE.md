# Authoring state

- Repository key: `29e9090a-7b77-443d-b953-9b1deef3bc60`
- Lifecycle: active implementation
- Documentation coverage: [derived requirement/execution matrix](TRACEABILITY.md) indexes all 37 active product requirements and all 17 approved unsuperseded project/design/plan/ADR records at `ced4dfaf3d31088287910ae7ac20243598f89401`. This refresh repairs navigation coverage, preserves all 23 frozen records, and introduces no semantic change or requirement/phase completion.
- Accepted project, requirements, and phase scope: [phase plan](artifacts/PLAN-29e9090a-7b77-443d-b953-9b1deef3bc60-25769985-feb8-5809-8833-b30f202730f7-v3.md)
- Verified documentation baseline: PRD v3 (37 requirements), PLAN v3 (15 phase/work packages), seven approved ADRs and the publisher-resource specification merged at `06772fc791df457f778265c092031f6402e1201c` ([PR #6](https://github.com/KleinPerkins/shadow-sync/pull/6)). The corresponding doc-warden delivery observations record this commit without changing frozen authorities or their original receipts.
- Verified tooling component: deterministic shard planning, source binding and evidence validation merged at `a15f01aafc1922bea0c108433acbbfd15da7541f` ([PR #7](https://github.com/KleinPerkins/shadow-sync/pull/7)). All 84 tooling/readiness tests passed in the [exact-head PR run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41634564668) and the [merged-main run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41634896124). This is component evidence for REQ-GV-06–11 and PLAN v3 P3-CI-02/03; complete application registration/execution, hosted transition/routine coverage and the ordinary reviewer-App merge canary remain open. Protected administration merged this component; no ordinary App-merge claim is made.
- Verified native-report component: the closed AppKit report contract and negative tests merged at `42197baf509c9cacefa09277471feed01e22c10c` ([PR #9](https://github.com/KleinPerkins/shadow-sync/pull/9)). All 98 tooling/readiness tests passed in the [exact-head PR run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41638373567) and [merged-main run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41638519182). These checks validate report structure and reject incomplete results; they do not execute the application or establish native acceptance.
- Historical private candidate runtime observation: all 35 registered executable suites and 311 expected case groups completed successfully, with source/binary hashes bound to the receipt and no new fixture roots remaining. The run used disposable fixtures with the real home and external network denied. This predates the current 201-file candidate and is not a fresh full-runtime qualification. It is local-toolchain evidence for an unpublished candidate; it does not establish hosted CI, minimum-OS support, a product release, installation, or UAT.
- Accepted native fixture design: [PR #12](https://github.com/KleinPerkins/shadow-sync/pull/12) added the fixture contract and native acceptance runbook at `d16532586792be2d309036de5a587bd34672f826`. [PR #13](https://github.com/KleinPerkins/shadow-sync/pull/13) adopted the process-limit successor at `654aa0c8a098c70e6d49826caa471c0c4c5d4483` after the attempted nested sandbox was refused by the platform. Frozen predecessors and failed evidence remain unchanged. The successor preserves fixture-only isolation, bounded lifetime, ownership, reaping, and fail-closed qualification.
- Prior 196-file candidate native observation: all nine M5 AppKit runs completed, covering 133 mandatory case groups including three latency trials. Every run verified isolation, child reaping, helper cleanup, and fixture removal. The helper qualification passed all 15 required cases, including actual parent death, lease EOF, lifetime expiry, malformed arguments, and termination behavior. Exact source/binary hashes bind these results to that 196-file candidate. They have not been rerun as full current-candidate qualification. They establish this native component only; full native-route registration, hosted CI, release-toolchain/minimum-OS qualification, installed behavior, and physical/visual UAT remain open.
- Prior 196-file candidate tooling and production exclusion: all 267 tooling tests and 24 fixture-contract tests passed. A separate production build excluded all 81 registered testing markers. The local development toolchain is not the accepted release-toolchain qualification, and the build is not a signed product artifact.
- Accepted production ownership correction: [PR #15](https://github.com/KleinPerkins/shadow-sync/pull/15) merged the specification and audit projection at `287d455506bdf8a0fd5d5b38cf84cf152854b818`. Both the [exact-head PR run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41666687452) and [merged-main run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41666996158) passed all 98 tooling tests. Doc-warden reconciliation was conformant at that merged revision.
- Prior private 197-file candidate foundation observation: all 16 M4 ownership case groups and 267 tooling tests passed against reviewed source; its production build excluded 95 registered test markers. This established OWNER-01 component evidence only. At that revision, production callers were not integrated and all five audited findings remained open. The exact receipts and preserved failed attempts remain historical evidence; native wrong-parent/borrowed-adoption refusal coverage is still required.
- Prior private 198-file candidate runner observation: CancellationToken, DescriptorProcessRunner and ClosedProcessRunner now share the same direct-child signal/reap owner. Independent review found no P1/P2 in this bounded change. Both affected executable suites (50 expected case groups) and all 267 tooling tests passed against the exact source; the production build excluded all 104 registered test markers. Both new actual-runner tests preserve an unreaped child while cancellation is paused before signaling, then verify exact terminal status and refusal of later signals. An isolated negative control that restores the separate raw reaper while suppressing termination signals failed both exact ordering assertions, with no timeout, leftover fixtures or lingering test threads. Successful runs denied real-home and external-network access and reaped their test processes. The preceding integration revision passed six regression suites (85 case groups); only testing-only timing and wait diagnostics changed afterward, so that broader receipt remains revision-specific historical evidence. Failed compilation and earlier control attempts remain preserved. This corrects the audited token/two-runner signal-reap race only. At that revision, two P1 worker/borrowed-child findings and two P2 cleanup findings remained open; OWNER-02/03/04 and native wrong-parent/borrowed-adoption coverage are incomplete. Fresh full 35-suite/319-case qualification is still required. Local-toolchain results do not establish release-toolchain/minimum-OS qualification, hosted application CI, installation or UAT.
- Prior private 198-file worker integration observation: WorkerSession stopping and WorkerClient adopted-child reaping now share one retained direct-child owner. Ownership failure cannot fabricate exit status zero; terminal and failure callbacks publish once. Native helper fixtures use that same production owner. Independent source and evidence review found no P1/P2 in this bounded correction. The exact 198-file candidate passed 50 M1/M4 runtime case groups, all 27 affected M5 UI/native case groups, and 267 tooling tests. Both positive and negative binaries passed all 15 helper-isolation/lifetime cases. Production verification excluded all 114 registered testing markers. The ordering fixture observes an actual contended ownership mutex before checking the unreaped terminal anchor. A signal-suppressed negative variant deliberately reaped through that exclusion and failed exactly the intended custody-loss/ordering assertion; additional assertion failures or duplicate diagnostics cannot qualify. Both native runs verified four helpers' terminal journals, original-identity absence and fixture removal. Earlier native failure exposed a takeover fixture passing raw signal status instead of the decoded exit code; it remains failed evidence with separately verified cleanup. An earlier production scan found only an empty test object's debug-path marker; the unchanged testing helper was moved into the existing testing-only fixture file, and the strict scan passed without an exception. This corrects the audited worker signal/reap race only. One P1 borrowed-child custody finding and two P2 cleanup findings remain open. Actual WorkerClient.start admission-failure execution, native wrong-parent/borrowed-adoption refusal coverage, complete OWNER-02/03/04, fresh full 35-suite/319-case qualification, other native routes, hosted application CI, release-toolchain/minimum-OS qualification, installation and UAT remain open. All application changes are still private and unpublished; the installed application is unchanged.
- Prior private lifecycle caller observation: production launchctl and codesign requests now use the existing suspended-admission closed runner with the shared direct-child signal/reap owner, isolated process group, closed environment, root directory descriptor and null stdin. The Foundation convenience reaper is testing-only and absent from the production binary. Launchctl retains complete nonzero diagnostics; incomplete output, timeout, cancellation and execution failure cannot be interpreted as service absence. Codesign requires a complete successful result. Independent source and evidence review found no P1/P2 in this bounded six-file correction. The exact 199-file candidate passed all 54 M1/M4 executable case groups, including four new lifecycle cases for status/output, suspended admission refusal without execution, ordinary timeout termination and output overflow. Every new case verifies exact-child reaping. All 267 tooling tests passed; the production build excluded all 120 registered markers. The runtime runs denied real-home and external-network access and left no fixture roots. Integration validated both exact runtime receipts and the complete reviewed source delta before replacing private candidate bytes, preserving all 21 preexisting non-source cache files. The normal interruptible timeout fixture does not qualify unresolved post-KILL cleanup. The shared runner's terminal deadline/retained-authority gap and the borrowed-child custody finding remain open, as do failed WorkerClient.start admission paths, full current 35-suite/323-case coverage, other native routes, actual installed launchd/signature behavior, hosted application CI, release-toolchain/minimum-OS qualification and UAT. The four new cases exercise the shared executor with disposable commands; they do not invoke real installation or launchd mutations. All product source remains private; no installed application changed.
- Production ownership audit confirmed three source-supported signaling/reaping races and two cleanup gaps under **REQ-SF-05**. The [correction specification](artifacts/SPEC-29e9090a-7b77-443d-b953-9b1deef3bc60-81b2dc00-4f47-5a79-be4c-519eea5ce71f-v1.md) binds the direct-child owner, complete caller integration, exact borrowed-child custody successor, and full qualification gates. A shared owner alone does not close these findings; no live PID-reuse incident was observed. The earlier SF-04 reference was incorrect: SF-04 governs the external matcher.
- Accepted custody successor: [version 2](artifacts/SPEC-29e9090a-7b77-443d-b953-9b1deef3bc60-32c6197d-8b18-5c72-afb9-c01c0e64edc0-v2.md) defines the per-command custodian, exclusive spawn/terminal anchors, bounded pending cleanup with retained leases, a mandatory expected-transaction catalog, pre-policy/readiness authority modes, and complete caller/test integration. The design explicitly requires qualified non-detaching fixed-tool graphs; group enumeration and output EOF do not establish universal descendant containment. Independent design review resolved the journal-loss, escape-assumption and final-admission findings. The original 22 frozen records remain unchanged. At adoption the 199-file private candidate remained unchanged; the runtime custody/cleanup findings remained open. CUST-01 through CUST-04 require implementation and exact native/hosted evidence before component completion.
- Prior private custody-anchor observation: the reviewed 200-file candidate adds exclusive suspended-spawn ownership, a proof-bound never-resumed phase, non-reaping terminal observation and bounded process-group drainage. All 64 expected M1/M4 case groups and 267 tooling tests passed against exact source/binary bindings; the separate production build excluded all 131 registered test markers. Ten actual custody cases cover capture failure, one-shot transfer, pre-resume cancellation without target execution, terminal leader/live descendant drainage, malformed group observations, concurrent finalization, ownership failure and signal/reap ordering. Native qualification exposed an initial stopped-event handling defect; the correction preserves the existing bootstrap contract and strict post-resume terminal validation. Independent review also corrected use of a system-wide buffer estimate. Failed evidence remains preserved. Both runtime suites verified isolation, exact test-process reaping and no leftover fixture roots. This establishes the CUST-01 anchor subset only: strict protocol, shared absolute budgets, retained registry, custodian/lease/catalog integration and complete caller qualification remain open. The full 35-suite/333-case roster, hosted application sharding, release-toolchain/minimum-OS qualification and installed behavior are not established by these component runs. No product source is published and no installed application changed.
- Prior private custody-protocol observation: the reviewed 201-file candidate adds closed canonical request/control/status decoding, bounded framing, fixed command-kind and descriptor-role representations, absolute work/cleanup deadlines and fail-closed admission sequencing. Parsed requests remain untrusted claims; they grant no executable, descriptor, publisher or lease authority. Twelve actual case groups cover exact-byte round trips, malformed/unknown/duplicate fields, identity bindings, descriptor manifests, resource limits, invalid budgets, cancellation, framing, sequencing and refusal to resume. All 43 expected M4 groups and 267 tooling tests passed against the exact final source; the production build excluded all 144 registered testing markers. Independent review corrected preservation of shorter caller cleanup intervals; a source-level negative control reproduced widening in the initial draft and passed after correction. Tiny positive work durations that round to zero are refused. Earlier failed interpreter-mismatch tooling evidence is retained; the final tooling run used the supported development interpreter. Runtime evidence verifies isolation, exact test-process reaping and no leftover fixture roots. This qualifies the protocol/shared-budget subset only. The retained registry, actual descriptor/lease/publisher validation, custodian helper, durable catalog/journals and production caller integration remain open. The registered 35-suite/345-case roster has not been executed in full on this candidate; hosted application sharding, release-toolchain/minimum-OS and installed qualification remain unproven. No product source is published or installed behavior changed.
- Prior private retained-lease observation: the reviewed 201-file candidate now retains actual namespace, lifecycle, operation and run file descriptions in typed scope-specific bundles. Atomic close-on-exec duplication is serialized with authority release; duplicate bundles preserve the original borrow lifetime. Read and observation roles do not gain mutation authority or initialize missing state. Descriptor type, ownership, exact permissions, ACL, inode and named-lock checks refuse drift. Retirement and staged admission permanently close new borrowing before releasing or changing authority; busy transitions remain closed through retry. Independent review found the initial retirement-first race and verified its correction. Fourteen new case groups include both retirement orders, concurrent release, partial-copy rollback, missing state, ACL/metadata drift and an actual suspended child retaining inherited locks after parent copies close. That case does not establish caller-process death or complete custodian behavior. All 109 expected M1/M4/M6/policy-authority groups and 267 tooling tests passed against exact final source/binaries; production verification excluded all 165 registered testing markers. A separate negative binary omitted only retirement closure and failed exactly the concurrent-retirement assertion, with no timeout or leftover fixture roots. Positive runs likewise verified isolation and exact test-process reaping. Failed compile evidence remains preserved. This is the lease foundation for the accepted custody design, not completion of CUST-01/02 or C07–C09. Retained registry, typed command context, helper/publisher admission, durable catalog/journals and all production caller integration remain open. The complete 35-suite/359-case roster, hosted application shards and unsharded parity, release-toolchain/minimum-OS, installed migration/update and physical UAT remain unqualified. No product source is published or installed behavior changed.
- Prior private custody-metadata observation: the reviewed 203-file candidate adds closed, bounded journal/catalog models and descriptor-relative durable metadata under the actual retained leases. A live scope owns a random identity and rechecks the catalog under its stable last-acquired guard for every reservation. Missing initialization, expected journals, unsafe metadata and unknown records refuse admission. Scope drainage, pending cleanup and expired work prevent further admission through that same live scope, including observation mode; a separate fixed diagnostic scope may coexist with valid pending evidence. Catalog reservation is fsynced before prepared publication. Terminal archive durability precedes catalog retirement and journal removal. Interrupted replacements retain preimages; errors during obsolete-preimage cleanup explicitly distinguish the already committed replacement and still close admission. Thirty-three new native case groups cover canonical/privacy bounds, lease-bound preparation, stale/concurrent scopes, missing records, atomic-write fault cuts, archive ordering and cleanup distinction. All 109 expected M6/M4/policy-authority groups and 267 tooling tests passed against exact final source/binaries, with isolation, direct test-process reaping and no leftover fixture roots. The production build excluded 206 registered test markers. A separate negative control omitted only the same-scope phase/deadline fence and failed at the drainage assertion, without timeout or residual fixtures. An earlier debug run passed all assertions but did not qualify because its broad fixture snapshot overlapped concurrent tooling; its failed measurement and diagnosis are retained, followed by serial final verification. The draft outer-sandbox build refusal is retained separately. This qualifies the bounded metadata component only: production initialization, helper writer transfer, terminal/recovery proof, retained cleanup registry, complete typed command context and production caller integration remain closed or unimplemented. The complete 35-suite/392-case roster, hosted application sharding/unsharded parity, release toolchain/minimum OS, installed migration/update and physical UAT remain unqualified. No product source is published or installed behavior changed.
- Prior private custody-resource observation: the reviewed 204-file candidate adds actual retained resources for the accepted custody specification (REQ-SF-05 and REQ-GV-06–11). Sealed read-only, unlinked request/input/code files bind actual descriptor identities and digests. A one-use spawn mapping retains normalized descriptors and the existing lease descriptions; only the caller owns the control writer. Bounded nonblocking channels handle backpressure and broken peers. Twenty-one new case groups cover sealed bytes, drift/refusal, scope and resource lifetime, exact EOF, actual child inheritance, deliberate inherited-writer and extra-descriptor refusal, occupied destination descriptors, and five partial-construction fault cuts with exact descriptor/name cleanup. Native investigation corrected use of a child destination for the working-directory action; the final child verifies the resulting directory identity. Independent review corrected an initial test that confused nonblocking read errors with EOF. Earlier failed evidence remains preserved. All 130 expected M6/M4/policy-authority groups and 267 tooling tests passed against exact final source/binaries with fixture isolation and cleanup; the production build excluded all 237 registered test markers. This qualifies the bounded resource component only. These resources grant no executable or candidate-access authority. The retained registry, complete typed context, verified initialization and helper writer/terminal/recovery authority, actual custodian, and production caller integration remain incomplete. Full current 35-suite/413-case execution, hosted sharding/unsharded parity, release-toolchain/minimum-OS qualification, signed release, installed migration/update and physical UAT remain open. No product source is published or installed behavior changed.
- Prior private retained-registry observation: the reviewed 205-file candidate implements the bootstrap and caller-retirement subset of custody SPECv2 (REQ-SF-05, REQ-GV-06–11). A bounded in-memory reservation retains actual resources before queued construction or spawn; a single serialized registry owns process and metadata transitions. Independent result copies allow a bounded pending response even while the ownership queue is delayed. Actual never-resumed/reaped proofs cover startup failure; resumed helpers receive cancellation/control EOF rather than deadline KILL. Terminal retirement requires exact request/resources/leases, actual helper identity and reaping, matching journal/status digest, fault-free bounded output and EOF, followed by durable archive and separate caller observation before catalog retirement. Twenty native case groups cover early cancellation, receipt/exit ordering, missing/wrong evidence, crashes, malformed and overflowing output, queued construction and response deadlines, capacity, lost handles, startup faults and retained locks. Independent review corrected four issues: ready-after-cancel sequencing, queue-blocked deadlines including startup, overflow hidden by terminal status, and failed fixture cleanup that could discard unresolved ownership. Final fixtures retain their owner and evidence on cleanup failure. All 150 expected M6/M4/policy-authority groups and 267 tooling tests passed against exact final source/binaries; production excludes all 270 registered test markers. Earlier compile/debug evidence remains preserved. This qualifies only registry bootstrap and caller retirement, using a fixed refusal-only native fixture; it does not establish a production custodian, helper-writer transfer, target admission/drainage or complete typed context. Full current 35-suite/433-case execution, hosted sharding/unsharded parity, release-toolchain/minimum-OS qualification, signed release, installed migration/update and physical UAT remain open. No product source is published or installed behavior changed.
- Prior private command-context observation: the reviewed 206-file candidate adds the typed caller context and two fixed diagnostic preparations under custody SPECv2 (REQ-SF-05/SF-08, MG-03/MG-06, GV-06–08/GV-11; CUST-02 remains incomplete). Factories bind actual held read/run/observation leases, account, caller identity, publisher and state-directory identity. External authority is weakly observed, so observation does not retain undeclared operation/run locks; disappearance refuses new admission. Context closure marks an in-memory gate immediately and delegates durable closure/cancellation to the retained registry, preserving exclusion during delayed metadata work. Only the fixed service-status and installed-signature requests are prepared, with bounded output and the original absolute budget; preparation creates no child or journal. Seventeen native groups cover source retirement/deallocation, lock exclusion, wrong/replaced state, missing/foreign metadata, one-use submission, paused metadata closure, queued retirement, fixed diagnostic resources and deadline preservation. All 167 expected M6/M4/policy-authority groups and 267 tooling tests passed against final source/binaries; the production binary excludes all 292 registered test markers. The earlier native fixture-home failure and corrected owner-private directory reuse remain in the private evidence. Independent review found no unresolved P1/P2 issues in this bounded slice. This is caller preparation/refusal qualification only: serialized target admission/cancellation, helper-writer transfer, actual target drainage, every remaining adapter, recovery and production call-site conversion remain required. Full 35-suite/450-case execution, hosted sharded/unsharded parity, release-toolchain/minimum-OS qualification, signed release, installed migration/update and physical UAT remain open. No product source is published or installed behavior changed.
- Prior private custodian-helper observation: the reviewed 208-file candidate implements authenticated inherited-helper bootstrap, helper-local journal ownership, explicit target admission, suspended target validation and owned drainage for the two fixed diagnostic kinds under custody SPECv2. Actual parent identity, publisher checks and a closed descriptor manifest bind the retained original lease descriptions; decoded records alone grant no authority. Native execution uses closed synthetic targets; production system-tool and signed-publisher execution remain unqualified. Thirteen native helper cases cover ordinary completion/failure, cancel/EOF, TERM-resistant KILL, output overflow, cancellation after admitted persistence and before target resume, late terminal delivery, and actual caller-process death. The parent-loss case observes durable drainage, unchanged operation-lock identity and exact operation-lock contention after the caller exits, followed by terminal proof, process absence and fresh authority. Independent review corrected nonterminal journal shape, terminal-commit/deadline handling and control-closure sequencing. Failed attempts and the test-budget scaling diagnosis remain preserved. All 180 affected M6/M4/policy-authority cases and 267 tooling tests passed against exact source/binaries, with fixture isolation, direct-process reaping and no residual fixture roots. The production binary excludes 322 registered testing markers. Integration also rejects unreviewed file-mode changes. This is local helper-component qualification only: CUST-02/04, production initialization/recovery, all remaining adapters and production call-site conversion remain open. The full 35-suite/463-case roster, hosted sharded/unsharded parity, signed helper/release-toolchain/minimum-OS qualification, source export, installed migration/update and physical UAT remain unqualified. No product source is published or installed behavior changed.
- Prior private 210-file initialization/recovery observation: prior-boot recovery preserves exact journal preimages, records interruption without claiming successful work, and retains the policy-revalidation fence; its independent 197-case/267-tooling qualification remains revision-specific. Fresh-state initialization now requires a verified coordinator boundary, a private existing parent, a stable initialization guard bound into the completed manifest, staged creation, original lock retention, control-inode-bound readiness, atomic no-replace directory publication, and a publication receipt. Ready-stage retries refuse missing/replaced controls rather than recreate them. Fixed per-destination temporary files resume only exact byte prefixes without truncation; an empty first-manifest temporary has not yet recorded guard identity, and no staged state exists at that cut. All 27 initializer cases passed, including actual child-process exit during temporary creation/partial write and retry, contention, legacy/existing-state refusal, corrupt records and missing/replaced original guards/controls. Across affected M6, M4, policy-authority and publisher-policy suites, 234 exact registered cases passed against identical source/binary hashes; all 267 tooling tests passed and the production binary excluded 371 testing markers. The publisher suite's initial missing-fixture failure is preserved; its exact pinned dependency was rebuilt as an ad-hoc fixture and the suite then passed. Isolated tests denied real-home/external-network access and left no test processes or per-test roots. The reusable fixture remains private for forthcoming qualification. Independent source/evidence review is clear for this bounded component; the 210-file source and recovery evidence are preserved in a verified private checkpoint. These results do not qualify the full 35-suite/507-case roster, intended publisher binding, signed coordinator dispatch, parent-directory setup, enclosing installation/legacy migration, policy-revalidation completion, remaining adapters/callers, hosted shards, release toolchain/minimum OS, installed updates or physical UAT. Product source remains unpublished.
- Prior private 210-file publisher-binding observation: application and lifecycle-coordinator trust checks require the intended Apple publisher identity compiled into the release identity and bound to the release contract. Source-contract validation includes that binding; policy-runtime packaging rejects mismatched metadata before dependency access or output. Independent source and evidence review is clear for the bounded eleven-file change. All 249 affected M6, M4, policy-authority, publisher-policy and release-identity cases and 271 tooling tests passed against the exact reviewed source; the production binary excluded all 372 registered testing markers. The added native requirement-expression case checks the intended-publisher constraint without creating signed artifacts. The integrated source and evidence are preserved in a verified private checkpoint. These are local-toolchain component results: signed-positive and wrong-publisher signed execution, the actual coordinator transaction, full-current-source runtime and native qualification, public source export, hosted shards, minimum OS, installed migration/update and physical UAT remain open. No product source is published or installed behavior changed.
- Integrated private 214-file coordinator-entry observation: the reviewed component passed all 35 registered runtime suites (508 case groups), 274 tooling checks and 14 coordinator-entry cases; its production build excluded 373 testing markers. These exact-revision receipts do not qualify later strict-state/native-runner changes, signed-positive coordinator execution, the enclosing installer or production caller integration.
- Private 220-file native-runner observation: the corrected testing build and all 305 tooling tests passed. Against that exact source and application binary, all 15 helper-isolation/lifetime cases and the full 35-suite M5 roster completed, covering 158 checks including split UI, combined legacy probes and all three latency trials. The executor denied real-home, network and outside-fixture writes, checked exact result coverage, retained direct-child ownership through drainage, verified helper absence and removed only verified successful fixtures. Earlier failed attempts remain preserved. This establishes local native component evidence only; the later rollback-correction working copy has not inherited these results.
- Private 220-file identity component observation: new predecessor backups use the permanent product namespace; existing historical backup and quarantine inputs remain explicit compatibility readers. Restored legacy installations stay stopped and unregistered. Independent review found and corrected preserved-plist validation against the wrong executable origin; the failed native attempt remains retained. The corrected exact source passed all 305 tooling tests and the full-source identity gate (11 exact file/token/count/hash exceptions, no unintended findings). Native execution passed all 10 predecessor-compatibility cases and 11 migration result groups, including current backup naming, historical repair/uninstall, interrupted-quarantine retry and refusal of conflicting namespaces without byte, identity or launch-state changes. The historical fault-cut marker names 12 while the source executes 13 cuts. All subprocess receipts report reaping and absent groups; fixtures remain intentionally retained. Independent source/evidence review is clear for this bounded component. Generated-artifact identity, cross-repository cutover, full-current runtime/M5 qualification, actual build-14 migration, signing, installation/update and retirement remain open.
- Remaining qualification findings: the preceding 217-file full runtime run passed 33 of 35 suites; the two fixture-initialization failures passed targeted reruns on an earlier corrected 220-file revision. These results cannot be combined into current-source qualification. Independent review of a proposed full-runtime executor found shared temporary-namespace observations that prevent same-host parallel execution, separately grouped helpers without complete caller-loss/timeout cleanup, and incomplete prerequisite binding. That executor was not run. A successor draft serializes local suites and strengthens exact identity/native receipt binding, but remains unexecuted and unqualified until helper custody and independent review are complete. Hosted sharding must preserve isolation and every mandatory suite; none of these observations closes source-publication or installed-safety gates.
- Runtime fixture custody implementation has begun under its accepted component specification. The testing-only registry preserves in-flight spawn reservations across cancellation and schedules each retained-owner callback independently of control observation. Independent source review is clear for this foundation slice. Eight native in-process state/concurrency cases and eight source-inventory tooling tests passed; one earlier invocation was refused by nested sandbox setup and remains retained. The source catalog now registers 36 suites and 527 cases, preserving all prior mandatory cases. This is not actual child-adapter, guardian transport, compiled full-catalog or full-runtime qualification. Resume atomicity, current directives and unique original-child registration remain explicit integration obligations.
- Private runtime-fixture ownership adapter observation: the retained original suspended child is registered before fallible identity capture, and actual resume is serialized with cancellation admission. Ten real-child probes passed on one exact 224-file candidate: pre-spawn and crossing-spawn cancellation, transferred/pre-resume refusal, cancellation while the owner is paused, normal exit and no post-reap signal, responsive TERM cleanup, resistant nested KILL cleanup, terminal-leader retention, original lease continuity, and failed-identity cleanup. The same candidate passed all 305 tooling tests and compiled discovery of 37 suites/537 cases. The isolation canary proved home/network/outside-write/unapproved-exec denials; owned fixture cleanup and exact input bindings passed. Earlier temporary-root and shell-dispatch refusals remain retained and are not combined into the successful run. The fixture now selects one explicit system shell so process identity does not change through a dispatcher. Four observer fault-injection tests separately exercised retention and admission fences. A prior production build excluded six new testing markers from all three products; that receipt remains bound to its pre-fixture-correction source. This is component evidence under the accepted runtime-fixture custody SPEC, not guardian control/status transport, M4/M6 adapter integration, full current-runtime coverage, public source delivery, installed behavior, or UAT.
- Private M4 runtime-fixture integration observation: all 43 original M4 case groups and 24 registry/original-child probes passed against the same exact 225-file candidate. The adapter registers each actual suspended child before fallible identity work, closes resume admission during normal fixture drain and case exit, and retains transferred owners through assertion unwinding. Injected ownership-failure cleanup is limited to proven original suspended children or the fixed descendant-free fixtures; ordinary poisoned-owner operations remain closed. An older runner-fixture join abort was replaced with retained pending cleanup. Independent source review also required attempt-specific temporary namespaces: three positive namespace checks and six sibling read/write denials passed before M4 execution. All original observer handles reached terminal states, no attempt fixture roots remained, and source/binary/profile/executor bindings stayed unchanged. The same source passed 305 tooling tests, the full-source identity gate, and compiled discovery of 37 suites/543 cases. A separate production build excluded eight newly introduced fixture-control markers from all three products, with positive controls in the testing executable. Earlier 23-probe evidence remains bound to its earlier source; the initially wrong Git-mode identity invocation is retained as a refused invocation, not a source failure. This qualifies the bounded M4 integration only. The canonical private candidate is not promoted; guardian control/status transport, M6 fixture integration, full current runtime/M5 coverage, public source delivery, hosted application CI, signed release, installed migration/update, minimum-OS behavior, physical UAT and compatibility retirement remain open.
- Private M6 runtime-fixture integration observation: all 186 M6 cases (180 preserved and six added), 24 registry/original-child probes, and 43 M4 regression cases passed against one exact 225-file candidate. M6 original spawns now retain custody through assertion unwinding, including the ACL fixture; native descriptor cleanup requires real channel EOF. The parent-loss worker uses serialized stop/deadline admission, cooperative cancellation and a bounded lifetime, while preserving intentional abrupt death only after target readiness. Its ordinary cleanup waits for the registry's actual stream and durable retirement. Six additions cover pre-readiness EOF, the cancellation/admission race, cooperative EOF, lifetime expiry, and both transfer-unwind cuts. Nine positive namespace probes and 18 sibling read/write denials passed. All observed handles reached terminal states and no successful-attempt fixture roots remained. Earlier native attempts remain failed evidence: an atomic marker write was denied inside isolation and replaced with reviewed staging/rename confined to the owned directory; a later strict-permission fixture required the established special-mode exception narrowed to seven exact-attempt non-executable state paths. No source assertion was weakened. Coverage compares each declared case exactly once because catalog order differs from execution order. The same source passed 305 tooling tests, the identity gate and discovery of 37 suites/549 cases; a production build excluded 14 fixture-control markers from all three products with testing positive controls. Independent review cleared the bounded integration and executor. This is component qualification only: the canonical private candidate remains unpromoted, and guardian control/status transport, full current runtime/M5 coverage, public source delivery, hosted application CI, signed release, installed migration/update, supported minimum-OS behavior, physical UAT and compatibility retirement remain open.
- Private runtime guardian transport observation: the exact 230-file successor passed all seven registered guardian probes, all 43 M4 cases and all 186 M6 cases through the new control/status transport: 236 cases across three of the 38 mandatory suites, from one source/build binding. The remaining 35 suites are not yet admitted by this transport; the complete 556-case roster remains mandatory. Twenty guardian qualification runs exercised normal completion, cancellation and caller loss at seven deterministic original-child cuts, pre-admission deadline/malformed-control refusal and status-reader loss. Five malformed-input runs refused an unopened FIFO and duplicates of each channel endpoint before readiness. Selected suspended cuts require actual unexecuted-child proof and marker absence; a generic failed terminal is insufficient. The executor retains its original handle, drains bounded evidence and closes later admission after observer failure or interruption; it never kills the guardian. M4 and M6 accounted for 17 and 20 registered original-child reaps, respectively, with zero remaining reservations, children or callbacks at successful completion. All attempt observers reached terminal states and no successful-attempt fixture roots remained. Full-source identity verification passed with 11 documented exceptions; all 326 tooling tests passed. A separate production build excluded 20 fixture/guardian markers from all three products, with testing-positive controls. The first native alias attempt remains failed evidence: opposite Darwin pipe endpoints have different inode identities, so the correction verifies both kernel-reported endpoint handles. An earlier tooling run lacked process-observation permission and failed three existing executor tests; the permitted rerun remains a separate receipt. The first exclusion positive-control scan could not find a short diagnostic literal as contiguous optimized bytes; the reviewed replacement tests the compiled probe entrypoint, while native qualification still requires exact diagnostic/proof output. This is bounded component qualification only. The canonical private candidate remains unpromoted; all-current runtime/M5 coverage, public product-source export, hosted application CI and ordinary App delivery, signed release, installed migration/update, minimum-OS behavior, physical UAT and compatibility retirement remain open.
- Private model-suite guardian integration observation: five additional suites (runtime custody, policy wire, policy binding, policy projection and release identity) now execute their complete assertion bodies within guardian case boundaries. Shared non-child fixture values are returned only after case success and cleanup. On one exact 230-file source/build binding, these 61 cases, the seven guardian probes, all 43 M4 cases and all 186 M6 cases passed: 297 of the mandatory 556 cases across eight of 38 suites. The remaining 30 suites have no guardian qualification; earlier results do not fill that gap. Ten new cancellation/caller-loss runs refused admission with zero begun cases, passes, spawns or pending custody. The 20 transport qualification runs and five malformed-input refusals also passed on this source. M4/M6 accounted for 17/20 registered original-child reaps; all observed handles were terminal, successful-attempt fixture roots were absent and the final process observer found no task build/test processes. All 326 tooling tests passed, the identity scan passed all 230 files with 11 documented exceptions, and 26 testing-positive markers were absent from all three separately built production products. Independent source/native-evidence review is clear. The first identity scan failed on a stale whole-file hash for the preserved legacy compatibility fixture; its reviewed correction changes only that hash, and both receipts remain retained. This is local component qualification under the accepted runtime fixture specification, not full current-runtime/M5 coverage, hosted application CI, signed bytes, installed migration/update, minimum-OS or UAT acceptance. Both the canonical private candidate and public application-source gate remain unchanged.
- Private closed-process guardian integration observation: the closed runner now retains the original suspended spawn through fallible ownership transfer and publisher validation, shares that same owner with cancellation, rejects resume after final deadline/cancellation admission, and retains the terminal leader until actual stream EOF and process-group drainage. The new ten-case closed-runner suite and existing policy input/transport suites run their complete assertion bodies inside guardian case boundaries. On one exact 232-file source/build binding, all 321 cases across 11 of the mandatory 39 suites passed; the complete 566-case roster remains mandatory and the remaining 28 suites are unqualified. Sixteen cancellation/caller-loss cuts verify phase-specific original-child cleanup, including never-resumed refusals, a held terminal leader with a live descendant, and observed output progress; another sixteen runs refuse before case admission. The 20 guardian transport runs and five malformed-input refusals also pass on this source. All original handles reach terminal observations, actual child counts converge, and successful-attempt fixture roots and task build/test processes are absent. All 326 tooling tests pass; the identity scan covers 232 files with 11 documented exceptions. All 29 checked fixture/guardian markers are present in the testing control and absent from all three separately built production products. Independent source, executor and native-evidence review is clear. Three failed native attempts remain retained: a fixed test pause failed to cross the existing scaled testing deadline, the lightweight ordering fixture incorrectly used its root as its home; and a stale EOF observation requested redundant termination after natural child exit. Reviewed corrections use the actual scaled monotonic deadline, a contained private home and one bounded same-owner EOF refresh after terminal observation; assertions, sandbox restrictions and production budgets remain unchanged. This qualifies the bounded component only. Typed production custodian adapters, durable pending recovery, full current-runtime/M5 coverage, public application export, hosted application CI, signed distribution, installed migration/update, minimum-OS behavior and physical UAT remain open. The canonical private source and its earlier qualified successor remain preserved and unpromoted.
- Prior private policy-suite guardian integration observation: historical-log, authority-file, host-policy snapshot and repository-catalog suites now execute each complete assertion body within its own guardian case and disposable state. Existing case labels, refusal assertions, historical byte checks and larger catalog inputs are preserved. ACL fixture commands use the retained original-child runner and verify exclusive reap. One exact 233-file source/build binding passed 363 of the mandatory 566 cases across 15 of 39 suites; 24 suites and 203 cases remain unqualified. The four newly integrated suites contribute 42 cases and 14 actual ACL child reaps. Twenty-four cancellation/caller-loss runs refuse before admission, sixteen closed-runner phase cuts retain cleanup custody, and the separate guardian qualification passes twenty execution attempts plus five malformed-input refusals. All successful-attempt fixture roots are absent; observed task build/test processes are absent. All 327 tooling checks pass, the identity scan covers 233 files with 11 documented exceptions, and 33 testing-positive markers are absent from all three separately built production products. Independent source/executor review is clear. The first expanded native attempt remains red: the compiled guardian catalog omitted four IDs and refused before readiness; its original handle was reaped and all streams reached EOF. The correction adds those exact IDs and a cross-surface catalog consistency regression. Three earlier tooling failures caused by sandbox-denied process observation are also preserved with an unchanged-source successful rerun under the required observation permission. These are local component results only. Full current-runtime/M5 qualification, typed production adapters and durable recovery, public application-source export, hosted application CI and ordinary App delivery, signed distribution, installed migration/update, minimum-OS qualification, physical UAT and compatibility retirement remain open. No canonical source promotion, installed mutation or release occurred.
- Prior private policy-session and publisher-resource guardian observation: both suites now give each complete assertion body fresh disposable state and retained child custody. Warmed catalog preconditions, malformed resource inputs, all original case labels and the 750 ms policy deadline remain intact. One exact 234-file source/build binding passed 386 of 566 mandatory cases across 17 of 39 suites; 22 suites and 180 cases remain unqualified. The two new suites contribute 23 cases, including actual suspended-child inode and native publisher/CodeDirectory refusal checks with exclusive reap. Twenty-eight cancellation/caller-loss runs refuse before admission, sixteen closed-runner phase cuts retain cleanup custody, and separate guardian qualification passes twenty execution attempts plus five malformed-input refusals. All successful-attempt fixture roots and observed task build/test processes are absent. All 327 tooling tests pass; the identity scan covers 234 files with 11 documented exceptions. Thirty-six testing-positive markers are absent from all three separately built production products. A source-built arm64 test executable replaces an unsuitable relocated system executable, with positive marker, exclusive-create, wrong-root, invalid-verb and current-nonce sandbox execution controls. The test executable rejects compilation without its testing gate; it is not a production artifact. Failed native attempts remain red: the first stopped before suites when the relocated system executable was killed, also reproduced outside the sandbox; the second correctly rejected/reaped a suspended child but exposed two stale error expectations. The correction catches the exact propagated publisher error and additionally proves an actual successful snapshot mismatch. Independent source/executor review is clear. These are local component results only: full current runtime/M5 qualification, typed production adapters and durable recovery, public application-source export, hosted application CI and ordinary App delivery, signed distribution, installed migration/update, minimum-OS qualification, physical UAT and compatibility retirement remain open. No canonical source promotion, installed mutation or product release occurred.
- Prior private runtime-ownership guardian integration observation: all 13 original ownership cases now execute complete assertion bodies under the outer guardian while retaining their intentional inner cancellation tests. Each successful original spawn has one actual anchor and serialized owner, registered with every active assertion scope. Resume admission takes a deduplicated outermost-to-inner ordering, including explicit ancestor selection; reservations precede the one spawn and every registration must retire before cleanup succeeds. The closed nested assertion probe restores the exact outer binding without reporting an extra compiled case. One exact 234-file source/build binding passed 399 of 566 mandatory cases across 18 of 39 suites; 21 suites and 167 cases remain unqualified. The new suite accounts for 14 actual child spawns/reaps. Four targeted outer cancellation/caller-loss cuts prove cleanup while a nested responsive child is running and while a successful spawn crosses registration. Together with existing coverage, the integration receipt contains 17 positive suites, 30 pre-admission refusals and 20 phase cuts; separate guardian qualification adds twenty execution attempts and five malformed-input refusals. All successful-attempt fixture roots, including owned nested temporary roots, and observed task build/test processes are absent. All 327 tooling tests and the 234-file identity scan pass. Thirty-nine distinct testing-positive markers are absent from all three separately built production products. The earlier exclusion check remains red because two thin wrapper names were not emitted after the shared implementation moved; replacement markers are bound to actual emitted testing-only session code and the nested-restoration assertion, with source/binaries unchanged. Independent source, lock-order and verifier review is clear. These are local component results only. Full current-runtime/M5 qualification, typed production adapters and durable recovery, public application-source export, hosted application CI and ordinary App delivery, signed distribution, installed migration/update, minimum-OS qualification, physical UAT and two-release/90-day retirement remain open. No canonical source promotion, installed mutation or product release occurred.
- Prior private discovery descriptor guardian observation: all three existing discovery-spawn cases now retain the complete assertion body, actual suspended spawn anchor, serialized original owner and synchronized nonblocking stdout/stderr/trace drainage. Existing borrowed-descriptor, source/destination collision, partial-allocation cleanup, exact output and exclusive-reap assertions remain, with explicit self-PID ownership refusal. Shared production descriptor construction preserves retained-source normalization and gate routing. A native diagnostic observed the original system Git launcher change executable identity before completion; direct developer Git is therefore pinned for descriptor fixtures only, and production launcher cancellation plus typed discovery adapter (C15) remain unqualified. The first integration attempt failed its trace assertion after reaping its child with zero pending custody. A separate closed comparison proved that the absolute trace destination was denied on pathname reopen, while Git's documented direct descriptor interface emitted the exact expected configuration event under equivalent restrictions. The reviewed production/testing correction maps the owned trace pipe to direct descriptor 9; no sandbox permission or assertion was relaxed. On the corrected exact 234-file source/build, 402 of 566 mandatory cases pass across 19 of 39 suites; 20 suites and 164 cases remain. The new suite proves two actual child spawns/reaps and four never-resumed cancellation/caller-loss cuts with all three streams at actual EOF. The integrated receipt has 18 positive suites, 32 pre-admission refusals and 24 phase cuts; separate guardian qualification adds 20 execution attempts and 5 malformed-input refusals. All 327 tooling tests and the 234-file identity scan pass; 41 distinct testing-positive markers are absent from all three production products. Source/binary/Git/fixture bindings remain unchanged, attempt roots are absent, and original handles are terminal. These are local component results only. Full runtime/native qualification, typed production adapters and durable recovery, sanitized public application export, operational hosted application CI and ordinary App delivery, signed distribution, installed migration/update, supported minimum OS, physical UAT and two-release/90-day retirement remain open. No canonical candidate promotion, installation or release occurred.
- Private qualified-command-graph implementation observation: the command custodian now requires a publisher-sealed, release-contract-digest-bound catalog of fixed adapter, platform and executable identities. The production catalog is empty pending real-route qualification; observing an installed tool does not enroll it. The original suspended spawn owner retains custody through permitted executable changes without adopting another PID. Expensive validation precedes final control consumption; single-use observations and absolute deadlines govern resume, known transitions require revalidation, and positive graph faults survive natural exit and block journal retirement. Native diagnosis found the system Git launcher uses a root-owned hard-link topology; only that fixed path receives the reviewed exception, retaining exact code, inode, link count, ACL and ancestor checks. Application/helper captures retain the single-link rule. On the exact 237-file candidate, the local component cohort passes 423 of 587 mandatory cases across 19 of 39 suites; 20 suites/164 cases remain. The new checks exercise the actual launcher transition, TERM/KILL, strict default refusal, expired resume, stale-observation revalidation, fault retention and prepared-graph cancellation/caller loss. The helper EOF case establishes suspended-target refusal, not deterministic arrival after preparation. All 327 tooling tests and the identity scan pass; 47 testing-positive markers are absent from all three production products. Failed pre-correction execution and marker-selection evidence are preserved. This does not qualify any production graph, the typed discovery route, journal-level graph-fault/descendant matrix, full runtime/native coverage, hosted application CI, public source export, signed delivery, installation/update, minimum OS, physical UAT or compatibility retirement. No canonical promotion or installed changes occurred.
- Private final-admission EOF observation: the existing helper EOF case now waits for a fixed testing-only marker emitted after the final resource/parent/target validation and signal preparation, then closes the sole control writer. A bounded pause observes readiness without consuming control; the unchanged production control-consumption and resume gate must refuse the suspended target. The case verifies empty target output, exact marker, original-child SIGKILL status, terminal journal, exclusive helper reap, retained lock exclusion and catalog retirement. This replaces the earlier nondeterministic journal-phase timing with actual boundary evidence; it does not qualify a production graph or typed discovery adapter. On the exact successor source and binaries, all 423 component cases across 19 of 39 mandatory suites pass, with 164 cases in 20 suites still open. All 327 tooling tests and the identity scan pass; 48 testing-positive markers are absent from the three production products. No canonical promotion or installation occurred, and the existing public-source, hosted application CI/App, signed delivery, installed migration/update, supported-OS, physical-UAT and compatibility-retirement gates remain open.
- Prior private discovery command-adapter observation: the actual discovery probe now constructs a dedicated closed read-only command before observers, descriptor allocation or candidate opening. Existing local inspection commands, stdout/stderr/trace limits and transport diagnostics are preserved; mutation/network commands, command overrides, test transport flags, trace-mode mismatch and invalid work limits refuse at that boundary. Two additional registered case groups exercise the command contract and actual entrypoint refusal. The exact 238-file successor passes all 12 discovery cases, six existing cancellation/caller-loss cuts and the seven-case guardian prerequisite; 327 tooling tests and the identity scan pass, and 50 testing-positive markers are absent from all three production products. These are 19 focused current-candidate cases within the 589-case mandatory inventory; predecessor component results are preserved separately and are not presented as a full current run. Review caught and corrected the fixture HOME setup and executor receipt bindings before native execution; a restricted-sandbox tooling failure remains retained separately from the passing run with process observation available. Original handles are terminal and scoped fixture resources are absent. The successful-spawn discovery route still needs the shared read context, authenticated repository/config resources, complete trace transport and custodian integration required by C15. No canonical source promotion, installed operation or product release occurred.
- Private discovery trace-custody observation: the custodian and retained registry now carry a separate discovery-only trace stream with a fixed 256 KiB bound, explicit descriptor mapping, complete output accounting, and EOF plus buffer drainage before retirement. Five new native/refusal cases verify exact bytes, overflow-prefix preservation, caller-loss drainage with a retained trace writer, non-discovery refusal, and inclusion in the 64 MiB aggregate reservation. Independent source, executor and raw-evidence review found no P1/P2. The exact 238-file candidate passes 205 custody/lifecycle cases, 12 discovery cases and the seven-case guardian prerequisite: 224 of 594 mandatory cases across three of 39 suites. All 327 tooling tests and the identity scan pass; 55 testing-positive markers are absent from all three production products. The declared lost-status negative remains incomplete/failed with verified drainage, rather than being converted to a success. Original processes are terminal and scoped fixtures are absent. Production discovery still refuses at the helper boundary until repository/policy resources, pre-policy read authority and pending propagation are integrated. Full runtime/native, public source, hosted application CI/App, signed delivery, installed migration/update, supported OS, UAT and compatibility retirement remain open.
- Private selection read-phase observation: production chooser, intent binding and worker rebinding now establish a shared custody scope before policy/candidate access, then release it before fresh exclusive hydration. Canonical-root confirmation borrows its actual exclusive authority through validation and commit. Weak admission callbacks reject an escaped binder before policy/candidate admission without retaining the shared operation lock. Independent source/executor review found no P1/P2; native cases prove normal/throwing scope release, escaped-binder refusal and borrowed-parent preservation. On this exact 238-file candidate, 251 of 598 registered case groups passed across five of 39 suites, including 209 custody/lifecycle, 12 discovery, 12 policy-session, 11 publisher and seven guardian cases. All 327 tooling tests passed; testing and production builds succeeded; 59 testing-positive markers were absent from all three production binaries. Isolation, original-handle terminal results and fixture cleanup were verified. These are local component observations: 347 cases in 34 suites remain unqualified on this source, and actual discovery/policy command custody, full native qualification, export, hosted CI, signing, migration/update and acceptance remain open.
- Private sealed-policy transport observation: the helper now authenticates unlinked, owner-only sealed input and code descriptors, their request-bound content digests and their exact target inheritance. Production policy execution remains disabled pending publisher/command-graph/caller integration. Five new cases verify exact input/code bytes, cancellation and caller-loss drainage, and missing-resource/output-limit refusal before spawn. The first native attempt stopped after 185 passes because a generic ten-second decoder ceiling violated the two-second policy contract; the reviewed correction selects the stricter command-specific ceiling without extending deadlines. That failed attempt is retained separately. The corrected exact 238-file source passes all 214 custody/lifecycle, 12 discovery, 12 policy-session, 11 publisher and seven guardian cases: 256 of 603 mandatory cases across five of 39 suites. All 327 tooling tests and the identity gate pass, both build configurations succeed, and 64 testing-positive markers are absent from all three production products. Original handles reached terminal states, scoped process observation found no task build/test processes, and fixture cleanup passed. This is descriptor-transport component qualification only: no supplied policy code executes in the new fixture, and it does not complete C14 or C15. Full current-source coverage, canonical integration/public export, hosted application delivery, signed releases, preserved-state migration/update, supported-OS and physical UAT remain open.
- Private production-policy custody observation: policy classification now uses the typed held context, sealed request/code descriptors, verified publisher resources and the one fixed bundled-interpreter graph adapter. The actual custodian reconstructs this authority and verifies the suspended interpreter; a decoded catalog cannot supply publisher authority. The original absolute deadline remains bounded by the existing two-second policy work limit. Cancellation participates in final admission and sends control through the retained helper handle; unresolved cleanup closes admission, preserves prior catalog state and blocks app retries/quit through actual reservation accounting. Independent review corrected cancellation arriving during validation, omitted quit accounting and reconstructed relative deadlines. A later test-only correction waits for both terminal publication and reservation retirement without weakening the final assertions. The first native attempt remains failed after 190 M6 passes: its new graph fixture emitted noncanonical escaped slashes and was correctly rejected before semantic checks. The reviewed correction changes only fixture encoding, and separately rebuilt production bytes are identical. On the corrected exact 240-file source, all 222 custody/lifecycle, 12 discovery, 13 policy-session, 11 publisher and seven guardian cases pass: 265 of 612 mandatory cases across five of 39 suites. All 327 tooling tests and the identity gate pass; both build configurations succeed, and 73 testing-positive markers are absent from all three production products. Raw receipts retain cancellation/loss negatives, actual original-child reaping, stream completion and scoped cleanup. This is bounded fixture qualification only: the release graph catalog remains empty, signed canonical production-policy execution and native chooser/quit behavior are unqualified, 347 current-source cases remain open, and C14 archive/removal and C15 real-command integration are incomplete. No canonical promotion, public application-source delivery, installed migration/update, signed release, supported-OS or physical-UAT completion is implied.
- Private system-config custody observation: a fixed five-second, bounded-output adapter now has typed context preparation, its own closed graph identity and independent helper validation. Production catalog remains empty and real configuration-capture callers remain unconverted. Eleven synthetic cases were added. Initial native preflight exposed an omitted explicit CI roster; the corrected roster has 623 cases across 39 suites, including 233 M6 cases, and a source guard plus two negative tests now reject body/roster mismatch. Both build configurations, all 329 tooling tests, identity scanning and 84 production-exclusion markers passed on that corrected v2 source. Native v2 then failed at the new ordinary-completion consumer after 189 M6 passes. A reviewed testing-only diagnostic v3 built and requalified the seven guardian cases, then reproduced the same native failure: the helper journal is completed with zero exit status and drained streams, while the retired caller result retains protocolFault. Static inspection identifies premature fault classification when the original helper is reaped before terminal/EOF observations finish draining; the strict consumer correctly refuses the contradiction. The registry correction and its ordering/failure regressions remain next work, not a completed fix. Both failed native attempts retain original-child reaping, complete output EOF and zero retained children/reservations/callbacks. v3 is not qualified by borrowing v2 tooling/production results or earlier suite passes. The canonical candidate, public application-source export, C14/C15 completion, signed production execution, release, installed migration/update, minimum-OS and physical-UAT gates remain open.
- Subsequent private registry correction observation: reaping the original helper no longer faults an otherwise valid transaction while terminal/status/output observations are incomplete. A real status EOF without a terminal frame, poisoned streams, nonzero helper exit, invalid journal or deadline still refuses completion; no recorded fault is cleared. Deterministic fixtures force reaping before status EOF and before output EOF, verify retained authority and catalog entries while reads are deferred, and then require fully verified completion. A direct ready-then-exit-without-terminal fixture requires protocolFault and retained custody before its deadline. Independent source/executor review found no P1/P2 findings. The exact 241-file v2 candidate passed both build configurations, 329 tooling tests, identity verification with 11 scoped exceptions and exclusion of 87 testing markers from all three production products. All 279 selected cases passed across five suites, including 236 M6 cases, with cancellation and caller-loss refusal cuts. The ledger verified 36 original-child execution receipts and 108 raw streams, exact source/binary bindings and no remaining fixture roots. All 626 mandatory IDs remain inventoried; 347 cases across 34 other suites remain unqualified at this source. Earlier system-config failures remain historical failed evidence. This clears the bounded registry ordering defect and its immediate adapter fixtures; production configuration capture/discovery integration, signed graph qualification, canonical promotion, full runtime/AppKit, hosted delivery, release, installed migration/update, supported-OS behavior and physical UAT remain open.
- Prior private selected-operation phase failed observation: the three selected hydration/inventory entrypoints now borrow their actual exclusive operation authority, freshly reclassify saved selections and validate the phase before returning completed inspection. Six new registered cases cover fresh binding, stale/duplicate scope, changed repository identity, pending cleanup, revoked phases and borrowed-lock lifetime. Source and executor reviews cleared the bounded implementation after correcting three fixture issues, but native qualification remains failed: the v2 run passed all 236 M6 cases, 12 discovery cases and the first 18 policy-session cases, then failed during the nineteenth case's initial catalog setup before its borrowed-authority assertions. Two testing-only diagnostic successors reproduced that failure; the latest helper exited with status 2, zero stdout bytes and 35 stderr bytes, without timeout, cancellation or requested termination. Catalog admission reported policy unavailable after approximately 101 ms, within the unchanged 750 ms budget. This narrows the failure to the helper/refusal path but does not establish its cause or a corrected production route. The original process and all 69 helper children were reaped with no retained custody; exact source/binary bindings and raw failure evidence are preserved privately. The diagnostic successors build and pass their seven-case guardian prerequisite; earlier tooling, production-exclusion and component passes remain tied to their own revisions. The current inventory is 632 mandatory cases across 39 suites; no combined current-source pass is claimed. Existing downstream discovery/configuration callers still require C15 integration. No canonical source promotion, public application export, installation or product release occurred.
- Private selected-operation phase correction and qualification: a bounded diagnostic reproduced the policy helper refusal as a closed inherited-code descriptor at fixed child slot 9. The production runner now duplicates that borrowed input above the fixed destination before spawn and closes its owned duplicate on every exit; the original descriptor and its flags remain unchanged. Temporary bootstrap diagnostics were removed. The exact 241-file v7 source passes all 236 M6, 12 discovery-spawn, 19 policy-session, 11 publisher-policy, 10 closed-runner and seven guardian cases: 295 of 632 mandatory cases across six of 39 suites. The nineteenth policy-session case observes the actual slot-9 normalization and completes both return/throw exclusive-lock preservation assertions. All 329 tooling tests and identity checks pass; both build configurations succeed, and 94 testing-positive markers are absent from all three production products. The qualification ledger verifies 39 execution receipts and 117 raw streams against exact source/build bindings, preserving intentional negative outcomes. Originals are reaped and scoped fixture roots are absent; the deliberate status-reader-loss probe retains its expected missing-terminal refusal rather than a fabricated complete status stream. Prior native failures and the intervening compile failure remain separate evidence. This qualifies the bounded selected-operation/descriptor correction only: 337 cases in 33 suites remain unqualified on these bytes, downstream production configuration/discovery adapters remain unconverted, and the canonical candidate is not promoted. No public application-source export, hosted application CI, signed release, installation, update, supported-OS or UAT completion is implied.
- Prior private typed configuration-caller observation: parent freeze, snapshot capture and postflight now receive the same phase-bound probe as selected-operation binding. A reviewed correction preserves cleanup-pending on callback return and throw rather than converting it into ordinary cancellation. Its three new regressions passed within 298 of 635 cases in six of 39 suites on those exact bytes; production compilation and actual capture-call execution were still open at that revision. Those receipts remain revision-specific evidence.
- Private configuration-capture and production-build observation: eight additional native cases execute the actual typed freeze, snapshot and postflight APIs against disposable repositories, with only system-origin resolution injected. They verify ordered contributors and frozen bytes, absent system configuration, changed origin/content rejection, forbidden includes, closed phase, wrong account and cleanup-pending. Testing snapshots use a distinct nonce-bound basename outside production recovery's prefix; own/foreign sandbox canaries and cleanup observations passed. Production compilation identified three optional-shadowing errors; the independently reviewed repair uses the existing session-bound completion validator. On the corrected exact source, 306 of 643 cases in six of 39 suites and all 329 tooling tests passed; both build configurations succeed, identity verification has no findings, and all 107 testing-positive markers are absent from all three production products. The ledger verifies 39 execution receipts and 117 raw streams; original handles are reaped and scoped fixture roots are absent. Prior compile failure, pre-correction source and native results remain separate evidence. This qualifies the caller fixtures and bounded repair only: real signed command graphs, deeper per-worktree fallback I/O, child-side snapshot validation and the legacy discovery policy reader remain open. The remaining 337 cases in 33 suites, full AppKit qualification, canonical promotion, public app-source export, hosted application CI, signed distribution, installed migration/update, supported OS and UAT are not implied.
- Private inspection-admission observation: the actual top-level, cleanup, lifecycle, maintenance and origin-head inspection APIs now propagate closed, cancelled and cleanup-pending phase authority through warning fallbacks. Per-worktree and moved-worktree continuations validate before subsequent filesystem work; session-process observation is deferred from construction until admitted lifecycle inspection. The maintenance planner now requires caller admission validation before registration access and preserves typed phase failures. Eleven new native cases cover the actual inspection APIs, direct worktree-state handling, closed/cancelled entry and ordinary unavailable fallback. Two cases use actual registration metadata with synthetic Git replies: pending proof at the first registration prevents inspection of the second, while ordinary proof refusals inspect both and retain warnings. Independent review found no remaining P1/P2 in this bounded correction. The exact 241-file candidate passes 317 of 654 mandatory cases across six of 39 suites, all 329 tooling tests and both build configurations. The replayed ledger verifies 39 execution receipts and 117 raw streams, original child reaps, zero terminal custody and absent fixture roots. All 119 testing-positive markers, including the registration observer, are absent from all three production products; identity verification is clean. The initial static-parser compile error and pre-planner-correction receipts remain preserved, revision-specific evidence. This does not qualify the remaining 337 cases/33 suites, full AppKit behavior, production discovery policy handoff, child-side snapshot validation, legacy transaction command integration or signed command graphs. Canonical integration, public application-source export, operational hosted application CI/App delivery, deployed safety policy, signed distribution, installed migration/update, minimum OS, physical UAT and two-release/90-day retirement remain open.
- Next action: complete the production discovery policy handoff and child-side command integration under retained phase authority, then qualify the exact full runtime/native roster before reviewed canonical integration and public export. Keep legacy transaction integration and signed command-graph qualification explicit; do not combine predecessor passes. Continue the accepted CI, safety deployment, signed delivery, installation/update and acceptance sequence at its separate gates.
- Source extraction, complete repository governance, operational CI, signed release, installed migration/update, channel promotion, compatibility retirement, and UAT remain incomplete.

The foundation and architecture merge is not proof of a working application or operational delivery pipeline. External safety and native acceptance gates remain mandatory.

Private evidence bindings (SHA-256; receipts retained privately, no raw host evidence published):

- applied.json: `43e1bf66daea171ed36406a14e164b32ed49030745be6eebc76215f5ea9fc41e`.
- build.json: `04f684efa63cc04a7dc0c3888c0f5f3dbea38dcf229b833c99f1f30da33a48bc`.
- production-build.json: `00d36686f97a133bf1cfe62adb9ae7f7804a092df096b8df0cc06c7c4a17bd35`.
- native-m5-v1.json: `942a157b2b3ecbfef20f0646ad82c0de93977146490552dd4bafe626e0ece147`.
- helper-qualification-aligned.json: `73264b6ea4bc11cc76e00905b15a68f0502eabeca48aaebb52c2d7f2144588e3`.
- tooling-result.json: `9626ce0623d710b9381babc8a7ef3e8dcdc19748c204ea4c961699383021d97b`.
- production-ownership-audit-followup.json: `4f71692df36b6f5afc75d31376cad41d784531e8cd0df391f61072a0a2244a6b`.
- production ownership audit input manifest: `b47dd7fe57ef236499b9b32d0a2c4a3145fa6ad51563bc8b345800559ff49ebe`.

Current owner-foundation evidence bindings (SHA-256; private receipts, no raw host evidence):

- production-process-ownership/applied.json: `efb758d52df0c4701be8d89c51906b9efa2787a58b6c902a22533820b38d50ef`.
- production-process-ownership/build-v4.json: `3fdb2eacb45089265292fb338c732fe6cd99cdb2d10d33eeaf1454257b346a7c`.
- production-process-ownership/m4-native-v3.json: `837ad08a383cae4446722671f1307921f25e5038703986700acc26da33978896`.
- production-process-ownership/production-build-v2.json: `a60bade591357758b5a614db804a3a1747a172310619f2a6bd62a67117739fc3`.
- production-process-ownership/tooling-result-v2.json: `d21d1696a944b64f9fcf7d2adfa10c5aa56e544273e55a78fadbd632a7f258eb`.
- production-process-ownership/foundation-review-outcome.json: `ee2d6ac72532ed45d680644fd5f8c1a61f8616812601fd6e3887a3d610a3e08b`.
- production-process-ownership/audit-result.json: `8ccfc99832d109046c1c8c40391a354c693053684bc868cc854bcf4def336820`.

## Runner integration evidence

These private receipts bind the observed component without exporting raw local evidence.

- runner-owner-integration/applied.json: `75230853f52c5a9d0ba9385d11e0da31925d46775ac400e19b7bf2cc586bd407`.
- runner-owner-integration/build-v1.json: `3309db726351435dd8e981109815131f21c5df12d9549e62410573b921ad5926`.
- runner-owner-integration/native-v1.json: `b355f066c2e905ae7ba927308369e3fd767f5e03c475efe37367fb59f26bf01d`.
- runner-owner-integration/production-build-v1.json: `8d18b8ef8c4e54760448bafd12617ac40a6203412f8f0e15f5e4a0d0a7532fb1`.
- runner-owner-integration/tooling-result-v1.json: `93fc2dabf623945c04f4a9ef19f8d565e7e1e9899fa4af524221d3fc5a1551eb`.
- runner-owner-integration/review-outcome.json: `bcdec8c4651260cf63623d8fb003710f4acac00ef89e68df61aa6aba38e4aade`.
- runner-owner-integration/verification-scope.json: `dbb9889c04e8711de51f45192c259663942351511ca08a6be4ca68988aed3c4e`.
- runner-owner-integration/timing-diagnosis.json: `9f354815354265be9ff749c839e7a4414e9302a037e3cc90d1dea541fe49eaa7`.
- runner-owner-negative/native-v1.json: `72c897b03d150eca9552f4f38fbb4da8067cd1a4d6b7486f4d4eeb467ba4f9f4`.
- prior-runner-integration/native-v2.json: `2cb3df385733bba2593fc4e4dd229815008bb35492b0a54475cb159bc2dc24fc`.

Worker integration evidence (private receipts; aggregate observations only):

- worker-owner-integration/applied.json: `85362f17ccb10e649436e40f792dc7c16422188fe726fa83de0ab6c084e9efab`.
- worker-owner-integration/build-v1.json: `728beea30aecac348eeb7528f3a8f3e92a2d8428cf33e0309fa95d4d886d8c48`.
- worker-owner-integration/native-v1.json: `f924ced5bd0682f05ef14a0fa31edca894210a8b2b1b08600f116dd37b4422e9`.
- worker-owner-integration/tooling-result-v1.json: `23091131534767bba37af64d19acc682a57e9dab8203bbf37375edb994c3a0da`.
- worker-owner-integration/production-build-v1.json: `9d4edc8646633ed1d1a8a2b65ccee42b484a0a082553154a5a4d7ab1e031e2d8`.
- worker-owner-integration/helper-qualification-aligned.json: `b0b74dfec97ba5f433c7919ff9876866a0bf64d771dbd82032a55bc93f072b89`.
- worker-owner-integration/probes-aligned/native-m5-v1.json: `cc8cc08828011814aa4d3752b1eb9ced52b2941bb421268c4e8942c5c2323ca5`.
- worker-owner-integration/review-outcome.json: `dcd0a776bb4aaa1fa0eba916bb3744059666f6abd150e7fcb59617950098a1f2`.
- worker-owner-integration/evidence-review.json: `c7378f84dc7c609fb87e1f66848d9046727b4bd127240af8f8bb11e2c1a29038`.
- worker-owner-integration/qualification-corrections.json: `91de1679ae70a277e8606fb79d9c6e94d3f508cb1d0d93a47682538ae5ff141c`.
- worker-owner-negative/build-v1.json: `0aa082d753ac17d2571a83bdf34a346ff4a774badce2ba36a90395cf9d77ea45`.
- worker-owner-negative/helper-qualification-aligned.json: `4034fc25b3e92e59336b8f6ecfef38bb9baf801892168cb2655be6d31f4373e4`.
- worker-owner-negative/probes-aligned/negative-result.json: `1d58751b1c056fb620b7e63f4e2afa335e6ef269b24b885ffcffb6330592cad8`.
- prior-worker-integration/probes-aligned/native-m5-v1.json: `63a0acbf8d1c6614dc0bff83965acf3eb957d31de87baa399fc27a2587fa7c7c`.
- prior-worker-integration/probes-aligned/failure-cleanup.json: `3dbf5b93c774c3c7fde5819f6d9fc800e0e2dbbd3212a783b59f402f2dd0da21`.
- prior-worker-integration/production-build-v1.json: `d2eae0df46f3d60bc37fed81b1c834cde1e3b903e1793e393451ef5c80121bef`.

Lifecycle caller integration evidence (private receipts; aggregate observations only):

- lifecycle-owner-integration/applied.json: `bfc925e5002dd3621ce5369ca93e26decbc7be9e5f3ac4945ae7801a53757e7c`.
- lifecycle-owner-integration/build-v1.json: `5cdf391a055c2944ba7615255e9ee4de181a185619172b7585bf58d9397866bb`.
- lifecycle-owner-integration/native-v1.json: `44f725f1889b49d30f0739148941f2886876166155feb9a253c8c7f6885652a2`.
- lifecycle-owner-integration/native-v1-m1.json: `c88996d75ba8f4e25bc0c2f6c731800ff1c628536fc1ba10b0fec5b7015c174a`.
- lifecycle-owner-integration/native-v1-m4.json: `4e23d497d04597ef67997b7d085c021c14d8c40ca222dd0afa76ac4f2fb463be`.
- lifecycle-owner-integration/tooling-result-v1.json: `7ec29725bf27ecf11adae560669e525cb0cfe2db3cd002d9767923d0cb92f8b6`.
- lifecycle-owner-integration/production-build-v1.json: `ebaea71911f83dd0a6fb5e9eb5058eefcf32e2cfd36c645cd71f084d4065e7cb`.
- lifecycle-owner-integration/review-outcome.json: `bb3c7d9ebb4c16f7e7eea2ffcc099f113d29e532429e72e7c619c2bc861de597`.
- lifecycle-owner-integration/evidence-review.json: `b27c244e1437095a9bfbf7f73e34cbd0e40d7899416dcce0a06139204a33a8b9`.
- lifecycle-owner-integration/runtime-import-cache-cleanup.json: `af9b9016fba45a117af1b8143746a179111da0ceaf9fd5c55b0ca218f42a02d6`.

Custody-anchor component evidence (private receipts; aggregate observations only):

- custody-foundation/applied.json: `b4a41173e659462815a3e9b599c88a45e7b9124507c943d97e8d6dbb190aa8d1`.
- custody-foundation/build-v3.json: `8817ef2be582108048454b15a7b6cae4682c8a695495c501db2d96e1a150728f`.
- custody-foundation/native-recovered-v3.json: `b23236de05c54d4caabc99cdc55a3eba2b5db84b5565d397651250319ac83ee6`.
- custody-foundation/native-recovered-v3-m4.json: `316dc8db6d3f5a864242703118bb92cbd35b8cfa5cf70e80d83507b2225ace49`.
- custody-foundation/native-recovered-v3-m1.json: `f8f9532e68f5302d246c5e1800fe07af1bb2dc1682f633fcf932d62b517ccfb4`.
- custody-foundation/tooling-recovered-v3.json: `b7bf430861c86d58a04f05cabca31e7cda9ca99875d6978f89ae5584216f6489`.
- custody-foundation/production-build-v1.json: `6735fd4a39f01c5c778d699d248d8f31935567eb566b129e0418a6b3bc97939b`.
- custody-foundation/review-final-v3.json: `9879331ab5cb3c33c175a7ed32d85616412675c4c9f0b7c54b5f4d40e100336d`.
- custody-foundation/evidence-review.json: `d53585e9eb16e13d91ad58e9f964e117338c7adef7d53c6759c509035dc222fb`.
- custody-foundation/native-recovered-v2-m4.json: `6e0424eb36af0a7e800509d41015fef6a9933cbdb45550d02b92ae54aa827aaa`.
- custody-foundation/native-diagnosis.json: `7593e3df1cddcbad49e13edbe625b5ecc25001b15092b13e2ff7456286c7ef3c`.

Custody-protocol component evidence (private receipts; aggregate observations only):

- custody-protocol/applied.json: `04f16f48ac748799c943faf31b1c61b1586048e9dc2bab32fb649e35330caaa1`.
- custody-protocol/build-v3.json: `5b930cad5ee9e9d0a99f70627baf5a80d329152b7c3c5aea8fffabfb491b5515`.
- custody-protocol/native-v3.json: `bb10c55315c14820b8b1d29b0658156e77f0fb183ee56c2c1417f5fa8f47d59f`.
- custody-protocol/native-v3-m4.json: `c05bec7dea309f14f110c0a3e024ece1bfcbe23b3f4ed554a64ec56476a4c2aa`.
- custody-protocol/tooling-v3.json: `f15e9a91cdbd92a969949dcc417e5ae1c9b77a74da66131a04b0c8d095173170`.
- custody-protocol/production-build-v2.json: `b61a00bf5845b480f309a47526090d4f695c295207761dd61be26a52642c697e`.
- custody-protocol/review-final-v3.json: `44ad21c85dfc0e0e1ea500251e2ee50599f3fc58d40e593502de0bcede624321`.
- custody-protocol/evidence-review.json: `880469156a759e975298ab8e7937e1bae1f2e350200a37759ba3f29e8a369f30`.
- custody-protocol/deadline-regression.json: `e5c9d498d5a11e839b8b90b12b0c255a75b5260dfe70b24cfc354afe5690e68d`.
- custody-protocol/tooling-v1.json: `a1e0edd7af9bf0a8822e74173c1d424b1bdec2e12d440a362d5e1491274ef142`.

Retained-lease component evidence (private receipts; aggregate observations only):

- custody-leases/applied.json: `f3f1bcef8bc5c0f47b8ee706850c997495270c768d28652d58c50c742f6ce430`.
- custody-leases/build-v3.json: `ca299235af40a2c8a620ebc7cc6e2cea75b594384d20f0a69d6f03d7bf272d1a`.
- custody-leases/native-v3.json: `bf2f402351bda2a5e494f10d5aa94c4997c8d25eb9b7ea1497ba3d838055ab1c`.
- custody-leases/native-v3-m6.json: `9f8d25210562cb8995bbcb8720af04cd014a1f23909109f9b1fceb5069d841e8`.
- custody-leases/native-v3-m4.json: `537d4d536ad6707cc800f435c6249ea5566810585d02509d23f9e4d60386df45`.
- custody-leases/native-v3-m1.json: `1cc480aecac89028c9eca1d0f4d831d08c066915d38bb9377ea82ae7629e675c`.
- custody-leases/native-v3-policy-authority.json: `e6f8372a58dfd0fe351dd0789bb5a6519c571d9052a651627569edc3b4b53210`.
- custody-leases/tooling-v3.json: `57b4419c27f11c95a6d9f7c2d855a5f36174d4586d534c7201dc35f3d1945bf2`.
- custody-leases/production-build-v2.json: `1bcc5fcb1be4788d8a1ecd617609c5a2ee37409f0e46affc08c3c3cf09cf8240`.
- custody-leases/review-final-v3.json: `614f7f33c5b3b1389c63c11a48a4bc971c34544f21f5563ce6c783994d3d474e`.
- custody-leases/evidence-review.json: `3c6d157292dfeece67025c8271dda10bcef698dae56d31155a32a80643193d6f`.
- custody-leases/build-v2.json: `e7913936bd9b3057b675d4c010eda0b09a2ae7788b50f8a61eafce38feae635a`.
- custody-leases/review-v1.json: `1a527d013e59779787e3fc83a9dd6f94242981fdeccb8597450a59f00c33347f`.
- custody-leases-retirement-negative/negative-v1.json: `34c3ba74ff20a29af64e0c17e2bcbdc02a60bdb267b4fc837d1c43d32da39d82`.

Custody-metadata component evidence (private receipts; aggregate observations only):

- custody-catalog/applied.json: `b36142a1c4182e3302122341be4525af457b166b33e52f355f8fa5363428209a`.
- custody-catalog/build-v2.json: `01ce10b7a36e461567fc13d038d0a4fe03e4fab621f05e32c4b64b7be22199f8`.
- custody-catalog/native-v1.json: `e259037c68f6c668a0213c023139a5d50915d76c2e57e1193104fdc11fa3c08e`.
- custody-catalog/native-v1-m6.json: `e9c2a0d413acaa902e29702a4cb09a83a2bab7f2009b39983af5d314f1c2b185`.
- custody-catalog/native-v1-m4.json: `181a55bce9238b00e62bc20af22208401b5bcc42b25285ab0f0cbc592602495d`.
- custody-catalog/native-v1-policy-authority.json: `4d5e5c5d401e927e423962b1d13429afb15d8d50209286604bcebad597be95a0`.
- custody-catalog/tooling-v1.json: `76c3eaea18e4a168a6473360a04ac667b78f85a28b8d1493785af9d21fada9fe`.
- custody-catalog/production-build-v1.json: `6e09f36a4d89867cb763e6c99eb76e37707dc1b3a7528c60170334faf2c67cf0`.
- custody-catalog/review-final-v4.json: `bd1b26962042b86712fadddcc77b7b78afbfcc6e887920afbd7c28c6ebf6f6a8`.
- custody-catalog/evidence-review.json: `b397e6fe73528b12617d303dbebd3ea8e5f9fabef1069b17a66d3bdd6b2c6aa7`.
- custody-catalog/build-draft-v3.json: `5e1c7daa6f04833224696daad7c261b5165fdfa8b0308ff1402e5ee6fb14154f`.
- custody-catalog/native-draft-v4-m6.json: `c4447f5b423f614da37ffa21ff1a11d7c0e18520b09f8f2dc7bdb669d25bd94c`.
- custody-catalog/draft-v4-cleanup-diagnosis.json: `166e5b3dac4e0e3b6f02fbe6fbfdf0359fe3700f8c512052ee4262f005a5c95e`.
- custody-catalog-fence-negative/negative-v1.json: `b1e7e282ad74ed103adb27abdf97f712ba28704f1503fd99a8f6a5c77f592cb2`.

Custody-resource evidence (private receipts; aggregate observations only):

- custody-resources/applied.json: `4f3df2d6e5b1b5dd44195f72e79d0d49f7e7234d349dfbb75c3030e1173abfcc`.
- custody-resources/build-v1.json: `862b20b12bd56076a70417a2d601f20df64d450471c9a16dde63a28f1f7c77f7`.
- custody-resources/native-v1.json: `7d3124a1747515e9cd39a46df303563299858ec941056f664ee54ec22c654a3c`.
- custody-resources/native-v1-m6.json: `4f7ae600b8c475af2e739161861e837114f203ad3b43b0a35cd0265fa6f5e56f`.
- custody-resources/native-v1-m4.json: `394e6df125810730c21628192b62722287ce1e8658a4680e3127a2558137688e`.
- custody-resources/native-v1-policy-authority.json: `0f2fe4a0089e7087a0368ffab52ba6e027e0ac9c37181163d4ee9b0f6a34f348`.
- custody-resources/tooling-v1.json: `e61538ecfe832aa4c8d003fa4b48ffa916f964b456159b253b5262eef9b23a45`.
- custody-resources/production-build-v1.json: `d38348b082319a912f60f3c7e9dd61a8381876e4d4cf0cf86cd931bf43081e5a`.
- custody-resources/review-final-v1.json: `b8108010dc1856d451c4c2454aa669c057ac721b4131ec41c4205fdc87e41756`.
- custody-resources/evidence-review.json: `c3e9a59363136b0820fbfff3b5c8b08c9d4b61247e71e1f20b63d09afbcefb70`.
- custody-resources/spawn-map-probe.json: `1cc79ab232572677fa0dd32bc83c99a27fec1721c48aa5f74a8439b4b6c67274`.
- custody-resources/native-draft-v2-m6.json: `dba59cc19f9055fb0de2d336f1f4193ba28756ed8717b1fca76e2decd9cd76ce`.
- custody-resources/native-draft-v3-m6.json: `31df127cb48b77f08ea9981c924f68800bbf6e50008869ea2804eb175aad433f`.

Retained-registry evidence (private receipts; aggregate observations only):

- custody-registry/applied.json: `a8831e5327eb33c4e23e15984c814129b323b2fa942a2116fa79b9b8056b6aeb`.
- custody-registry/build-v1.json: `86e83d4e51c29d2a8b38791bd8052ec0f80be642954dae95ad2e9704dc4e0003`.
- custody-registry/native-v1.json: `670cf9b70d78494816971b5a3cabdc48f14be45caeaf67237dc5c6e572ccf342`.
- custody-registry/native-v1-m6.json: `699b7c20f538978902a25e86cdd0c0394b30d3c5f021ff6ad56e2c0788b2313b`.
- custody-registry/native-v1-m4.json: `d027b0ea425b02920eb5bfce481f8ec2e94089ee29b12af019837298d2550b7f`.
- custody-registry/native-v1-policy-authority.json: `79c2a643ba26589d2f96dc7d8563dfd1777c955f25679f2bf4731146530c9845`.
- custody-registry/tooling-v2.json: `56359f53bb8ef498335afa0d541ca27900d027b11a476f5f847b25f67d04feb1`.
- custody-registry/production-build-v1.json: `7663a5a52aad25299ec6ac19c50d5385783e5cd52e6aee2e9eee822d3957a26d`.
- custody-registry/review-final-v1.json: `c2542bbf5da0de51cf519c933cac004154ff5e21a4ba9de44b0e87afb8e2addc`.
- custody-registry/evidence-review.json: `fa6a531fd1ad3d9d12b47d552d9c9e8683a2d77e679582613d562ab097c8263a`.
- custody-registry/review-findings-v1.json: `0637b0a889f7fb516f200171751defe786abba806a87503a79556e7f2b071c07`.
- custody-registry/native-draft-v6-m6.json: `deb77334d316f12a25e5fafb53b47af84043c396ad3d1b3b4ea727f3d6438c1a`.

Command-context evidence (private receipts; aggregate observations only):

- custody-context/applied.json: `d97d461259ff0af8e072638201559be49996eee55e07f69192728499e55959a7`.
- custody-context/build-v4.json: `7e152d8d777c29cc86e63680b39283ad86ff5b27cd15ddf1fd7ba3fe7e93ecdc`.
- custody-context/native-v4.json: `2f0ec6969750fb6bcfcbe4d0c53e42857d3dbc95f800518269dfb05c1794f6ed`.
- custody-context/native-v4-m6.json: `6fc5783e4ca45f837622b4addc809a6794e06523e1a53ff2aa18e230341d680f`.
- custody-context/native-v4-m4.json: `f6f2cf27cb4c0131294944ae5e924faefcaccd2304cc5b3e4fb1a671a2aef107`.
- custody-context/native-v4-policy-authority.json: `1cb88778c88916aa12061d4b64f3483e4e7e7a219075735b280d55530cef4dd7`.
- custody-context/tooling-v3.json: `465f7f716b064f81f5c19cd25bc2fff09f9fc25dd58a8e006a3cb82a906cff15`.
- custody-context/production-build-v3.json: `6b421620d8116cca1b533921bb4249109f29c52aa47fae586f6be02b4dbab77f`.
- custody-context/review-final-v1.json: `e529872aa476bbf8b31cb5af5e8b31191af39e28a713eed86a64d12af4cbcd92`.
- custody-context/evidence-review.json: `39873cb49849841ac11589a7df7ab3fa6544242dfcc23e58ed8edf2eba3c700e`.
- custody-context/review-findings-v1.json: `34b3591c06712fce4869bf66e99f5fdfbcdff53e6b500e61f7a762879e70f2da`.
- custody-context/native-v3-m6.json: `0d6c3a192075fc5167c45c906729ceef81524adaa8cb1e1bdad82332f7347879`.

Custodian-helper evidence (private receipts; aggregate observations only):

- custody-helper/applied.json: `ad0e802086daf3c4582d01614e1b9ad82cff4c2ca49a92aa0c96fe7b75cf49ab`.
- custody-helper/build-v7.json: `c2cff33cc98653e34b6d59757d1b1a06cb928f9f762c97fcc3ef88422a7f1a4b`.
- custody-helper/native-v6.json: `4937b2c3d2e1b39f4b0c02922a800b3358af7c2af34432804cd7b96d662550c9`.
- custody-helper/native-v6-m6.json: `76fc426cb320156f0ed5954d0a027e17088d0fa315bca51788b3baad508bb05f`.
- custody-helper/native-v6-m4.json: `3d517661454eb1b641b50481bcab19b61a2cae405b0b6d18d4970ea2667f6777`.
- custody-helper/native-v6-policy-authority.json: `7ce1e6d9348387e8fa7c7d2aafbb37c086f40190bd38e122b7026270b64221aa`.
- custody-helper/tooling-v7.json: `b9ab29b0b833608081dd86b5bd469521d2b36f83f282c8e14e2b2574cf8e80cf`.
- custody-helper/production-build-v3.json: `07fbea884f6f04c64594cadf7c298243717098b4952b5d2d0049ea7d4785dbb9`.
- custody-helper/review-final-v3.json: `f5377d8266eeec9a1fac7cf2e6b9b4e774c78058998197738cbb9ce79d9efdfd`.
- custody-helper/evidence-review.json: `3db6e4e43006a8f6943cb7ad044a9de901fdfd2c8dcb5788fc3dc4449ea0a11f`.
- custody-helper/mode-guard-evidence.json: `37558f66185a5682afb902ae8d32ff1751a45fcd76abdc3c8a3271395653ff50`.
- custody-helper/native-v3-m6.json: `cf136e75310fba0a151bfc4b95a47c6eb42c66a9cd8907ab8ed735de854cac87`.
- custody-helper/native-v4-m6.json: `a7c197e86850052e239abb15fc9baa156828bf4f945dc1e8463e6505b66a2583`.
- custody-helper/native-v5-m4.json: `2a80b301953e8f221020987c1237d5a08a141bdaee031970f11fd6a42547cbd4`.
- custody-helper/checkpoint-v22-receipt.json: `b3d07559d82ed4ba5bb1acde0b3c761fed42bad1a74a14adf764f8b69f57c354`.

## Initialization and boot-recovery component evidence

Private receipts bind the bounded observations above; no raw host evidence or credentials are published.

- recovery/applied.json: `e4a5fc3e669a84bd335504e6780f0d6bfa8ed31092487ba29b34ca6a0cc84367`.
- recovery/evidence-review.json: `d83dd7bdcedb315e7553f8ffc568975de520fa0650fb521db10bcf1b71d0d79c`.
- recovery/native-v1.json: `1aa0d9e85de5d83d36a3bce9a092979f8fe0738d8d2b215353cdd47a1d2d9ebd`.
- initialization/applied.json: `075cd9d0e41c4000810cb4cdf6cd700a912c5b8306cfbfe5f766ae23fe46dcfb`.
- initialization/native-qualified.json: `5a0c94137f6ecaf6df99534219c6dfa9151220e2b073eaa1dd710e06c272b785`.
- initialization/build-v3.json: `a7793f034f371ad1f5412ea6918e6100f779630a0c4165f143deb9f059f81b3a`.
- initialization/production-build-v1.json: `39cc24c82cc74eecc0aec15e9b309fb34b9067c04b9fc62a42f5a25718376d35`.
- initialization/tooling-v3.json: `f8703291e72401cc96d945d5d6a6e2dcfe8af83619186f7d3d923d09ec39d98f`.
- initialization/review-final-v3.json: `3c6cf309f8993821b4b510d04ba94f2cce61a08f155d8a42cdbb8814aad3df26`.
- initialization/evidence-review.json: `a39fae6b67f9c152c29c34bacf792484fe38cdc34253462d89ad5dc5fe58c6a7`.
- initialization/publisher-fixture-missing-observation.json: `e98e7b54e36219e0f66eded4099ad42f73d422bf920137355f9ae97a2225cd39`.
- initialization/checkpoint-v24-receipt.json: `e5bb21ea53e1da36633c2f078d6e6ae4dfe57367e0b1b0b6a82a08dc797ff052`.

Intended-publisher component evidence (private receipts; aggregate observation only):

- `native-v1.json`: `3d02ea35b98d24a2a5102d7833324066cd86e2beda380d749a7ffd99c55b71ea`
- `tooling-v2.json`: `f152f0e4da0d0898315842afffc237bc70c8a242c5fe72d54efa27664b29acc5`
- `production-build-v1.json`: `864be8a15e271c77dc383abb114f0becdd8514e0fff8bb671763a98bfa20ac7a`
- `applied.json`: `891d2b403f67be7fca41c3c5c6644470b87c3f24317b1c39df44c80551cbcbca`
- `evidence-manifest.json`: `55910ad2406475e6dde9adf7f92ac047541ec1251907f3bfd05a9edd422f6951`
- `evidence-review.json`: `6968a7492d97842392214ed7986a7d0a9550fc1b67a8e876200acd5317b65835`
- `checkpoint-v25-receipt.json`: `5d611daf41ee49b18413e5389809af65e132967a8ebca0dd31f4a11979f48932`

## Coordinator and native-runner observations

Private exact-revision receipt digests; no raw host evidence or product source is published.

- `coordinator/applied.json`: `9366f0dd3390a23ad2faa8021fa1fbe4b813ba78eb9a06b4b4595bd05ad97b12`.
- `coordinator/full-native-v1.json`: `f0e299c89a8ad9ab0c040bf9e9ed596c8e25ee16d7bdecdbaef4135d37d4f8b4`.
- `coordinator/evidence-review.json`: `9c7bd2d7fda09931451caf88bc0e31b0b4b76a871198548e3a29ec4d5202e6b6`.
- `native/build-v6.json`: `5aaa9edaffbd741fc025e6cf51eb10be7de252d54c55562cdc8546f7c64e42ca`.
- `native/tooling-v6.json`: `7451dfaa69056c94ffe198eb17c984c4998f748ffb4c8e72db5668c226506b46`.
- `native/helper-qualification-v3.json`: `4d781985787d157adac3e77e0d052f41333fa2777c7344b35dcb8cf5bb9c5417`.
- `native/native-all-v3.json`: `7b2eb0706de1a42b22b24b15963dfc324576cedc705feaea515e026e416ed65b`.
- `native/native-all-v2.json`: `2882e179d53e1897d83ea5663aaa0d9d2653921b8e5b133f5716d3cc9043ce3a`.
- `runtime/full-native-v5.json`: `4683a4835d24b26831597d6e36f62917c8ebd83d1294dd81efa35b137b8a457f`.
- `runtime/native-m2-v1.json`: `2462f61de8f6ebf8ccb4737a4c469d18317bdbdd2801b252ec95071bf7f5828a`.
- `identity/identity-gate-observation-v1.json`: `72acf0f4e4c402e2c7ef0585be34139afcee7b0f5ce16f10881766ba87cf065d`.

Identity component and runtime-executor review evidence (private receipts; no raw host data):

- identity-completion-v1/build-v2.json: `e482cb87914a8891213f50fb03fb5f57ffe1b2878089bea3e427c594d1649cbf`.
- identity-completion-v1/tooling-v2.json: `18b0fc421e646005177d77f4166e34b05fd32715b3db5ea860d0d41cf2285b14`.
- identity-completion-v1/identity-source-v2.json: `05e21713fb6a18e1372e85fb6661b26ba64ee4bd10656fd53b742a6628e09c19`.
- identity-completion-v1/identity-native-v1.json: `5cceeec2d53786ea688bcc6b44f29a34665ad4ecfb80e21cb8c1bc53d090c245`.
- identity-completion-v1/identity-native-v2.json: `39b1f14e2af4167b9930a96f3561f4d1416b41d29c3d793b0c7857a5a134bde2`.
- identity-completion-v1/identity-evidence-review-v2.json: `7294811a8a2c5469132219f56d94288bf4bd3b67ca57501c3b81f16d7c76b6a5`.
- identity-completion-v1/runtime-executor-review-v1.json: `d6b7229e35a6ca8c5b16056d17418a1effd049d4d67928abe9fedce13092653b`.

Runtime custody foundation evidence (private component receipts):

- runtime-fixture-custody-v1/foundation-v1.json: `cfa377efda08581612459396a9466699db8994c689ec719ffde5d2f967a95a82`.
- runtime-fixture-custody-v1/foundation-v2.json: `4d1854a0683cdced800e4f39a75e264ee0c25309586ed7d2f7d565855f4efdda`.
- runtime-fixture-custody-v1/foundation-review-v1.json: `ef11d0ad9e499b68de52893edf8619f536668d1d5b8e8a81f86eaa74410ff9b7`.
- runtime-fixture-custody-v1/registration-v1.json: `0a83d3517cc9c48d597c5edfd128c4c40c5e06a5604bd157d06a790fa7895e8b`.
- runtime-fixture-custody-v1/inventory-tooling-observation-v1.json: `90f50a499d0e26ee0062ca8fc673200ef428d8d7d88d6f4c8e6e46705f6c750e`.
- runtime-fixture-custody-v1/source-inventory-v1.json: `0abeaa7d048b56e06d0d20a29e148f6ceecc7ec31688395335b722f634bab075`.

- [Runtime fixture custody specification](artifacts/SPEC-29e9090a-7b77-443d-b953-9b1deef3bc60-37618186-09f2-595f-bb4b-2908c75ad137-v1.md).

Runtime fixture original-child adapter evidence (private receipts; source and scope remain separately bound):

- runtime-fixture-ownership-v1/build-v4.json: `903d6eee4973c25582f71ec36ca767c0e4a70d135193893b14a54fc59b324988`.
- runtime-fixture-ownership-v1/native-ownership-v4.json: `4eda54a14fcbfa12a76b28064152c98177aa3549cd57a5aa5e1f81cf7ac845e8`.
- runtime-fixture-ownership-v1/tooling-v3.json: `32e7d9896abc4961bdb1101ec1c0344d7afb21a0b2472c40b8bdf6fdb8488d0d`.
- runtime-fixture-ownership-v1/identity-v2.json: `a49f7b16e1b0fe157cfa5342c91377de3b354c384a1d18a978e70d4f012b3fc9`.
- runtime-fixture-ownership-v1/executor-failure-tests-v1.json: `ba55e858d3ec3eff6063d6f76be6cdeee99ff8febf9b788163c17df5bcb87362`.
- runtime-fixture-ownership-v1/review-ready-v4.json: `f7f66e47266ec78448196fd02fd2d0cc9d4257d9e056b467a62767869fe6bc3e`.
- runtime-fixture-ownership-v1/production-build-v1.json: `8eed772371bc47957ca117d57329b1edc063144338e0e35c56e8562216624fda`.
- runtime-fixture-ownership-v1/production-exclusion-v1.json: `1c52aecee6489b76ce602575a7480ee4a129558087db78d1cba5fa543ff0e982`.
- runtime-fixture-ownership-v1/native-ownership-v2.json: `6300620b412f61bf975a9ace64c0da6aa8de226c84de0f95ba77b5133d835ba4`.
- runtime-fixture-ownership-v1/native-ownership-v3.json: `e7f0fb4d5d3a555311109882dae52d9390e09b548892805b0003543481950e08`.

M4 runtime-fixture integration evidence (private, exact-source component receipts):

- runtime-fixture-integration-v1/build-v3.json: `050e2506999f9677309d45637a6caa40663c180515f9ca5b7c55fec486aa72fb`.
- runtime-fixture-integration-v1/tooling-v3.json: `53e1b496f24dab8e76c16cb49d3396305ca3c893815ad837b50ffa1818ae4e89`.
- runtime-fixture-integration-v1/identity-v4.json: `17ee6923b80489217c131c08a55fc6bc2dc9d7a07696d9f05f5c236854574d01`.
- runtime-fixture-integration-v1/native-admission-v3.json: `81cc2822e520d621e29ad3ea7c1ed5d2832cc9cb058518883d7e0c147f4d0442`.
- runtime-fixture-integration-v1/native-m4-v3.json: `f2b871e4365bb1da304792dde0e77f0bbedbd6e1a1502ed3baf39b34955ef67d`.
- runtime-fixture-integration-v1/production-build-v1.json: `4a06b730b430244d17397e184d1a99f503cd7db84f8b6eca4fe1f895e1496579`.
- runtime-fixture-integration-v1/production-exclusion-v1.json: `549b617e2941d5425c618893f81b65fa620204635c60cb02189abf61d3d82adc`.
- runtime-fixture-integration-v1/source-review-v3.json: `0da73fbb83bb0fb49782ba4aa57001b938fb78330dd62c0ed82e8007a31598c1`.
- runtime-fixture-integration-v1/process-cleanup-v1.json: `c2fd66b5b0102f9b27b186fc3971c216f3d4a29c186916aab439037179bc31d9`.

## M6 runtime-fixture integration evidence

Exact component receipts are retained privately. These bindings do not imply full current-suite or installed qualification.

- runtime-m6-integration-v1/build-v4.json: `a8e37cf38187877f6e2ccb2ed39a1eac5322e9f3718b264355280525f85d6a0d`.
- runtime-m6-integration-v1/tooling-v4.json: `9dad28667a34a23c18a052a078d64620ec6401036db5ec5ff808a062ca98c7e2`.
- runtime-m6-integration-v1/native-m6-v5.json: `09d0078ed8802b5efc2fc395d0b360ee06663cb9c92576a3d45b2cf491d1bc5e`.
- runtime-m6-integration-v1/native-admission-v4.json: `31a45cd1cb37351acd6e05f9123912ffa04eb5c94fb014b0a4246aba2cfe4ad6`.
- runtime-m6-integration-v1/native-m4-v4.json: `86cc9a5c297d6cb890b21b16b6c7fc87ace7462d71b907492bdc3a2f44921270`.
- runtime-m6-integration-v1/identity-v4.json: `50eec068994c90e626e16ef1618fdbd2d19c31e8e0fdae5aa535e55c3733be5e`.
- runtime-m6-integration-v1/production-build-v1.json: `b995613529798df2fa46896fb12dff31a7ee11bdfb7a2fd810a0337bb9e05f36`.
- runtime-m6-integration-v1/production-exclusion-v1.json: `255feb844a6f40007e852d5232652924950131c2ac03cd49b103c6b93110a04d`.
- runtime-m6-integration-v1/review-v4.json: `f10ed6dc9cb39fe771066ebd7135b6a3f3d3df2e3f770c9bc44a82de1301c4f0`.
- runtime-m6-integration-v1/diagnosis-v1.json: `3ad769ff15d29492cd0009460adb599f3be32412d890efc2d4e913cea885f8b2`.

## Runtime guardian transport evidence

Exact private receipts bind the component observation; prior failed attempts remain preserved. No full-runtime or installed qualification is implied.

- runtime-guardian-transport-v1/build-v4.json: `4b1b055fec33054f236fcecb6c7c41a4b60061f49a923436c5763a74c22b53e8`.
- runtime-guardian-transport-v1/tooling-v3.json: `ab853b780d0724961195eec3b3d42f3b88cb4899fd637cc50c36c4316a47c148`.
- runtime-guardian-transport-v1/native-transport-v2.json: `039349009dffee4e92fd48297d82c2ce5b6960e3907ae840d38da4c85974a761`.
- runtime-guardian-transport-v1/native-integrated-v1.json: `8022cb888462bc8ee806e87da0986df9a19895e53b46e98b702da9d0897fe8e3`.
- runtime-guardian-transport-v1/identity-v2.json: `7e08952256d2ea1a206a0b69c1221a1c4c7ff82a893b67fac6dfc0fb23beea34`.
- runtime-guardian-transport-v1/production-build-v2.json: `c3b63f6a1bde39940687a4211254313ae3540a57ec7f189469d9179d5623da0b`.
- runtime-guardian-transport-v1/production-exclusion-v2.json: `ed23581dd457eb89221c294895b32f4e640a34a479fd956ebf9f348378d5d7c7`.
- runtime-guardian-transport-v1/review-v5.json: `f1ad79ba2a03745c6f2c4979d3758ceb35a5d9519b2d0c55889f75d35283a0b2`.
- runtime-guardian-transport-v1/review-v6.json: `11ba06f315cfb21b88ef238b0d40c82fbdd4e0f8471ebf4b991d50a767a3569e`.
- runtime-guardian-transport-v1/pipe-peer-diagnosis-v1.json: `442aec6ee3471ca56cffe0123d0b0b009d6c05d3f6268bf44d32c0527b52c391`.

## Model-suite guardian integration evidence

Exact private receipts bind this eight-suite observation. The preserved initial identity failure is not counted as a passing run.

- runtime-suite-coverage-v1/build-v2.json: `0d565c9a6c1342931f5083bdf58abe240a3c5db91a4672d370d384499411e65f`.
- runtime-suite-coverage-v1/tooling-v2.json: `ed4a65b7874b3d006a9a3405efac1610429cdde60ff8bbfdf5eb1d89336c2ab3`.
- runtime-suite-coverage-v1/identity-v2.json: `82bc848bcefcde4d9196f649a431debda629d086c6f765a87ca744e15b77aea9`.
- runtime-suite-coverage-v1/native-transport-v1.json: `2280e4016bfc3ea1992c4cbba58f9a9fc67569b6bd50266c97d2602f00110c01`.
- runtime-suite-coverage-v1/native-integrated-v1.json: `05a7ec7215948f533ab40b794fff5531bbc69dca871095005cc9f7d386e1794f`.
- runtime-suite-coverage-v1/production-build-v1.json: `18a51771646d3f94f7378f386a9e0c464ba4e5fddf69581bcd1d7c74d49b4702`.
- runtime-suite-coverage-v1/production-exclusion-v2.json: `746f3892d85eebd837996e02b3774a2e7db642782627d4a6837fb5d818ed7553`.
- runtime-suite-coverage-v1/review-v3.json: `d66335d70ec3435f75e6da7b4be211f258d59564a15c843638322b22d68d5e78`.
- runtime-suite-coverage-v1/process-observation-v1.json: `6ac7e27bbf8cdbaf43b858cb4828335f2bdbb7fb81f9a0e0fa454db868c252aa`.
- runtime-suite-coverage-v1/adoption-ledger-v2.json: `a778c5775b76a9ed5662293c5c74d1685cda38e7e0e5eacac6762498c060bfbf`.
- runtime-suite-coverage-v1/identity-v1.json: `ffe8adf0680420dea59c6e502f80272e0125af8599c6a7ba25763aa5d0967ee6`.
- runtime-suite-coverage-v1/identity-rebind-v1.json: `fe4ab40250204ed61afe76bb0501e8b37a5c09d361e8095a7892cd98681cfadd`.

Closed-process guardian component evidence (private receipts; aggregate observations only):

- closed-process/build-v7.json: `017022b680a4dd8358e8ff0105a5bce0f2483b2fb5ccf0568a8f367329f8904e`.
- closed-process/tooling-v4.json: `8054d1299a66ce4b9a713cd3527b6c68b742fe58dc9a40576aa250080fe6bc4d`.
- closed-process/identity-v4.json: `cf25c7fad90e03b009d55fbd061ea7621d0b840a7cd6d82336cdd5ea64c79c87`.
- closed-process/native-transport-v4.json: `9ce1f9f913dcc60adabc00c55efe0bac02d05ab09895493f4fa1b45b472bebb7`.
- closed-process/native-integrated-v4.json: `f81dce426d75a2183a64e8802822da15d3adb75dd4e717b19a1bb10093737c16`.
- closed-process/production-build-v4.json: `7a3ed146ceb6d8dbe522a2d03eeb42619d903d99d5c3ffbf90fa4454651d131d`.
- closed-process/production-exclusion-v4.json: `f207ddbd75ea69ea4c84f9762ac33ed44eb48d4558e7629d6f933be2f95271dd`.
- closed-process/review-v1.json: `7eb5199125188519b83af27cef55a4bb1f10806bcdfd40d259071bd4e3ea8446`.
- closed-process/review-v2.json: `0255b10a8cb606c4cdcaa41e184538abf6dca97661e2f3ba5b0f15a2c7d101b4`.
- closed-process/review-v3.json: `7fc735a6b7cf9ae6583a93481a26ad20cdc6e2501ef0678655f9b7affed41150`.
- closed-process/review-v4.json: `828b0a624cb41cf99f51e6c1029959f6f9957cbb45e69678b7ccdfe4d0d32053`.
- closed-process/evidence-review-v1.json: `41d416609f9bf7b75a2030c95b28c1d5b31d1a464255a703379db681abc975f2`.
- closed-process/native-integrated-v3.json: `2efcf34ca16b47dab3b044ea58a6888f81e8196b5e0f550d38d4567284b6109d`.
- closed-process/native-failure-diagnosis-v3.json: `45324838b2d9a0ba7e21a022f6890da4a7f2a346f4f202418fdb963943c992bc`.
- closed-process/native-integrated-v1.json: `b18fdbd0814924530bd24ca5fec4b518bbb8336125308bae621d19e315399fc6`.
- closed-process/native-integrated-v2.json: `beadbff75e444f8f69f8d20b9e264b2448b0e895324261d8dc4125954f0a1b7c`.
- closed-process/native-failure-diagnosis-v1.json: `6d054bb3335e98b281db58dd70f4312e1d478e32763e54e35a7b74dca4ec9a70`.
- closed-process/native-failure-diagnosis-v2.json: `6cb722a31a1b45c15612982243bbd8ab2842565d5d0bf6ebbecb45da9252a24e`.
- closed-process/process-observation-v1.json: `39c044ce754e8818b20fa725a881546bb03d87936ab45ddedc07e713cb1ccab7`.

Policy-suite guardian component evidence (private receipts; aggregate observations only):

- policy-suites/build-v2.json: `2f4ff7aa9c10fae0d68147caf4dd9a8122091918ee51a6086fa3c112010521af`.
- policy-suites/native-transport-v2.json: `06759307cbe84ff3ad565be033a03d16bd94dd1f79a6ba7e2b2e24184c1d7940`.
- policy-suites/native-integrated-v2.json: `4949f6a227f6b80661f496635f3d2e4d35035ee3c29401371955ce6e099572eb`.
- policy-suites/tooling-v3.json: `fd6e79adb9462a0062c933410f4835cc2262d79782ff47fc5e18cc6ca85c873e`.
- policy-suites/identity-v2.json: `912984111fb8397a41f535d79123ba64788a7088bdde03377d9fd861e8f41866`.
- policy-suites/production-build-v1.json: `8f6c879458182d47cb9f31bdaec300bb062abd077f1dbf9b6dae43ec36f2877b`.
- policy-suites/production-exclusion-v1.json: `697e821e529c2a543d51a2f9582c792851ae9d34dcd03347f5dd36775d45ebce`.
- policy-suites/qualification-ledger-v1.json: `03c47169a3e8fcb5a6b8e1475fe3dbb57a9d3aa7b46752ab34ec9ec5c518eba4`.
- policy-suites/review-v1.json: `870ee44e427d7dcfa1cda94cb5063bcc8cea242e65dfffdd9708a1c7e9625b24`.
- policy-suites/review-v2.json: `8010c13012cba90631ca37802916b6bf24959073a2e1f1b03a7e17b721658f6e`.
- policy-suites/process-observation-v1.json: `ddd58a97a2039cc6fb25c7fe8528e1b9afd29dcf58ee2a586d12c9c284f0c03f`.
- policy-suites/native-integrated-v1.json: `81a520a273ef4c675362990fce92ea4d268236a903778a6a249b15d7de94b55c`.
- policy-suites/native-failure-diagnosis-v1.json: `dfc0572c44281b215648f32c24254967937077b2a6cd383e135cad4d9a7c7c5b`.
- policy-suites/tooling-v1.json: `ab8858e40bf34c99689f772302d5e631fe675ff3ec89f178704b76ab8e093522`.
- policy-suites/tooling-v2.json: `cc15d86f78d26c0077f3e9d53add38a048913b323511410e65aa1daf62b7fb76`.
- policy-suites/tooling-failure-diagnosis-v1.json: `4759d483656f23072af07d9ca1e985789664f6b2bcd37ff48a9d17dba692a261`.

Publisher-suite guardian component evidence (private receipts; aggregate observations only):

- publisher-suites/build-v3.json: `2b462f1195aaac42123fbcb6b5a3b8cec1c86e59593b80c5680ba833f2ee063a`.
- publisher-suites/native-transport-v3.json: `2df0b5489fd4befb395d80524c07abcc67269707744e4295212321c17a75c6a4`.
- publisher-suites/native-integrated-v3.json: `21e71b596eecf54ebbb39358949471e31eefc8623757eaf2d21234fbe0bbebf5`.
- publisher-suites/tooling-v3.json: `59fd39b6435c249335077dc653bd8eab54998b8c5bd598f90d9991e8174174f0`.
- publisher-suites/identity-v4.json: `f8d2b6d882c151bc764771c33752485ba399ca0f24d9d4b7647d5146727404dd`.
- publisher-suites/production-build-v3.json: `33cda52ce6c05db43097d5f7d585b628451254592fc065463f837cde52937f65`.
- publisher-suites/production-exclusion-v4.json: `717b5adca4efb287bee789484c969c2217d5ef05e95710f467d13392e7f3b500`.
- publisher-suites/qualification-ledger-v3.json: `0e6e5668a59994e3a9ae70cb2838519cb7d4b476237606f29c680c4ce99009f2`.
- publisher-suites/execution-fixture-v2.json: `b8f12bb54c5260225b8e7279773af9a6b3c53dce8f4342ae2d066aeb73eadfbe`.
- publisher-suites/execution-fixture-production-refusal-v1.json: `37187439384a3d90a991a93a0593b9bd1d8c4cf54db90aca1f6946d3213f68d5`.
- publisher-suites/review-v1.json: `29a6af5ec3c2a11aa6caea4064a4022325c266d831e768c6e4f58fab5496c1ff`.
- publisher-suites/review-v2.json: `0a6954c7739a5dd561f067b64d453496ad74a60c6537263760a9b06a0903f8d5`.
- publisher-suites/review-v3.json: `04328c9d5a6de5e4c1224a929aa9782fe49ae43b20bf2b36ebb272990183cc72`.
- publisher-suites/process-observation-v1.json: `6a6f155754330cca8a8a11a86584de3c873794db41b8a4fe339a7d2d7f8b9288`.
- publisher-suites/native-integrated-v1.json: `2441270374ad18d38eea9efb133412fe21fc8984bf1ab1d485db2d08acc9ee12`.
- publisher-suites/execution-canary-diagnostic-v1.json: `d14b9448103fd7a3935a0908e803bc8235bea6a36fbf050ad640d4a9e8a8f725`.
- publisher-suites/failed-canary-cleanup-v1.json: `d1c06ed47e248439ff38e3930ad5dea0262d4e49eefe319839351b2f791b50b0`.
- publisher-suites/native-integrated-v2.json: `bb20a92d4dc7655b3f41135a7f6c70b8c0868815aa7a475bf04e189a079afcf2`.
- publisher-suites/native-failure-diagnosis-v2.json: `b8e7ccdd63a38f4de059224e9efb0e327a30bda0203d677fc580b9390bdf20ed`.
- publisher-suites/execution-fixture-v1.json: `82610e960977183dbaa6237ff90d905c6901236693921886f0ab711a47f6faea`.

Runtime-ownership guardian component evidence (private receipts; aggregate observations only):

- ownership-suites/build-v2.json: `654db1a6ef589126d7d6add76531770f6d8670978a2e68a1af657e48bbbaf1aa`.
- ownership-suites/native-transport-v2.json: `d653322f543be0f05a074601b8a003c6f3c998c3afe66f75666ca9a4ee2c3481`.
- ownership-suites/native-integrated-v2.json: `cadbc7280a36620bcbf6631ce15a0ab5394dc62ee5f1e2c20c39e2ac6d42f81d`.
- ownership-suites/tooling-v2.json: `3a5df7ebc5523ffcd05a04649c2c77730d3460fe6bc0a6ec67016ed9e28deffc`.
- ownership-suites/identity-v2.json: `10829b351324348f36e717d2187c50dfe495b42054cfb6d530e213f8824e0cdc`.
- ownership-suites/production-build-v2.json: `c5a5cab906c53cd4a35454800eddf40411ebc87f6f9a0d0c3c3497437c9bec21`.
- ownership-suites/production-exclusion-v3.json: `abe91df1da80a12238b11e60aa00225e3912ecaa83d417b4e582084c0a617613`.
- ownership-suites/qualification-ledger-v2.json: `8b6b9c74e711be64d3dd1332e1e00c16901cef34246a5bd0662963c5a1728e41`.
- ownership-suites/review-v1.json: `753f810a5ab80daa87c88e86f2f2f122cf14a529f8d0361a014b15c038823b95`.
- ownership-suites/review-v2.json: `f0afd80a16b1932cf5318f714d616ef60c288acfff1689ccb874db248b89fd38`.
- ownership-suites/review-v3.json: `d415f42074480076803f000efff6fda3817e43976405d094534fff1c553f5e1e`.
- ownership-suites/lock-order-review-v1.json: `f0d4b822b6b09271cfd5621ee48c709d51b8bc9a7520cb4f203f9fc81bc11eaa`.
- ownership-suites/process-observation-v1.json: `90d35d2c45724c511459602f628e32cd673e21a133125518b3e34200fa07d067`.
- ownership-suites/production-exclusion-v2.json: `8a69221a2b252335a19e96e1494c00baab1769d211d727df51f4edf0e959e399`.
- ownership-suites/production-exclusion-diagnosis-v2.json: `728ff492ee6b033013c323fc83c9a09075e1e51ca4571a64832240d3f4cbcaeb`.

Discovery descriptor component evidence (private receipts; aggregate observations only):

- discovery-suites/build-v2.json: `afdc668a738e0df2cf9ca5212e93ae83f38beb9bf93905f1165d793e22be8867`.
- discovery-suites/native-transport-v2.json: `a30584f84f7a58b6ea832b15a776e4f9aafa551e4565e8fbb0539871b2c153c7`.
- discovery-suites/native-integrated-v2.json: `c5609d094d25daa0c7f1301f833fd8c4d59fa4afc2841e329e7d1bb3abe213ca`.
- discovery-suites/tooling-v2.json: `3f162b33c89bf303f378abac744e02ede4133e424748012ad738065dda937082`.
- discovery-suites/identity-v2.json: `7e7d09e8188dd6af49f646726481a75715ff759f888cff2af5bef39d4af8573c`.
- discovery-suites/production-build-v2.json: `105ede91d78b43df9fc8f66820d3d6f89891a99eb46f103f711d985f28240cca`.
- discovery-suites/production-exclusion-v2.json: `9c98417cf72a6abb7a51e3025cedb8467a65699af4ea1ae0812391cb86d866ba`.
- discovery-suites/qualification-ledger-v2.json: `56327ff2e5a84fb5e27162d4fc4f878dc96831da051c5175936b36e14ea67401`.
- discovery-suites/source-review-v1.json: `c20222e7b2298bdf096b358c68dcb251c88e352da3e9d3bfb2b7f5b87cf79123`.
- discovery-suites/executor-review-v1.json: `4a1e04d87a001bc1902e6df83cd3fcaf71686650b73df1ff41d2b6b05a5756f0`.
- discovery-suites/correction-review-v2.json: `2eb1c5d2c67dbe0d5fadb0f0508f47e63e7015a78aa885613f998b675a433267`.
- discovery-suites/process-observation-v2.json: `e9432fa6b4b8634b72377af94cc9a261f5585990314cd08675b8915cb322b749`.
- discovery-suites/git-fixture-v1.json: `070e0f7f5ebacf3e00c7b8333b2893d6b0d41231a0b40b98177659d4d7d14f1a`.
- discovery-suites/git-graph-v1.json: `5cbe7dab38072a7ead39771ff92b3403325f0b489c5ff4a9794025315b212193`.
- discovery-suites/git-trace-v1.json: `a660f37719444df3b85bbfd477915eb9531fadbef10f2c3341f9ca30b757e192`.
- discovery-suites/trace-failure-v1.json: `f7aecb73080dabd2858957cfdb4ed2b4766b4dd01521770bd657de0395cc95e3`.
- discovery-suites/trace-correction-v2.json: `c9af3792886e1412dae0f1d351ffa8561bd70881ff944c1db2886c4026b6fbbc`.
- discovery-suites/native-integrated-v1.json: `c9f822faa8b8a62c1a0e23b0aee73df3529d7d2d056383fe45fd95257b43ded1`.

Qualified command graph component evidence (private receipts; aggregate observations only):

- command-graphs/build-v4.json: `a73e6e6f918fc0849e8de7030ef305227ba643dcd1197f4a992085f5cde864db`.
- command-graphs/production-build-v4.json: `c58741a5a4c7ef53542805005c6bfa95d9b84566f0937e7c1418c0a9b8552eeb`.
- command-graphs/native-transport-v4.json: `420a84bc9b198e439f13be3155d4c878215057d30cad9739357f24f004dd7981`.
- command-graphs/native-integrated-v4.json: `268494e49d1adf658f64ed16cfc04a240824b6b92048a67c7486b7e7f9b6616d`.
- command-graphs/tooling-v4.json: `841aca4f08f490f65dcef81d66814f365ad546143025df9b2b4fe6599c1a4520`.
- command-graphs/identity-v4.json: `db8424c9871c1fd2cce6555a698f8a6faa2b2372e6819bc30b113fbb70704b48`.
- command-graphs/production-exclusion-v4.json: `db4b3f7e50ca200373601a3d7a0d52cef9d8abc8a0d20d32ab1961b36f8305b3`.
- command-graphs/qualification-ledger-v4.json: `0514f83c54dcea93730ada37d2bb7132acc4d618eb8bc8396fcbdb8669812cbc`.
- command-graphs/source-review-v4.json: `575ddff2ecfe7721d1c4321ac81ccd58bbc03f0639d87ff5dc29b14975d637dc`.
- command-graphs/process-observation-v4.json: `39a3d5a7c5b1742b910cb1d40cf9a9ae991d47262ab962828afe70de22e6f0a7`.
- command-graphs/git-launcher-v1.json: `708ce0da64144e4ccf05f92c7848b4f636e59ddf8d4d677b0fe0feba6aa5843d`.
- command-graphs/diagnostic-v1.json: `1f271c21671919ee0ae563ce07affad524985b9957b11f89c9bb14389cde6906`.
- command-graphs/native-failure-v3.json: `ae6c84c214f4ab26c1132aa784b2c88662be67bf7f0b1fdeb6639a3f87b4e576`.
- command-graphs/native-integrated-v3.json: `1ca6d4b0b79469b3b9b7771e4aeef4190fdfd246b1c0fa3e99f5ee2bb1f4fae1`.
- command-graphs/production-exclusion-v3.json: `d7215d92f310387c62739668ebbd51b29097d0877fe31bf0fa99e3a39e918c71`.
- command-graphs/production-exclusion-marker-diagnosis.json: `dc92c89c1622b215c561a38f7f47873848543b605afe10328227baafda99d0c1`.
- command-graphs/platform-v1.json: `143bf123ecbe141dc400775ebf046d22fde0c2037ceb5c7576e24d1d0e68434a`.

Final-admission EOF component evidence (private receipts; aggregate observations only):

- helper-final-admission/baseline.json: `888ab287b3c5ebf64f9f68903a899a62ac6b4a0142672b1ba840a48183b64fe9`.
- helper-final-admission/build-v1.json: `7d210b61d4da98edf5b75827d5934c9764332c32430da1cf1be844c5ebe10a4c`.
- helper-final-admission/production-build-v1.json: `0e13dbd3234838a20bcc6147fe02641d8b424626b54d4e132030042c0a11d5b5`.
- helper-final-admission/native-transport-v1.json: `8a0abc3f5338ee970a84acac7a06cc0ccceaee61aa4b2232a76aad733a0b1a86`.
- helper-final-admission/native-integrated-v1.json: `17ec7cea9e42521d54c645721e0dcb1b04d543d4a8bdc0f2d904dd487b19f9d6`.
- helper-final-admission/tooling-v1.json: `000b16147790bd0a913aa3b8cc745daf1c66ce6a8bdeacf52b1ab6a2a40d79b3`.
- helper-final-admission/identity-v1.json: `238e926fdb4d2fae52d4d28b0c0cee1844af89fd71dbd6031b07c66fc4cfee01`.
- helper-final-admission/production-exclusion-v1.json: `7900b2d29f9e574aa54464619dcf1381109ca58c0a767f39bf1fcf201fae83c0`.
- helper-final-admission/qualification-ledger-v1.json: `1afcd8e881499488e23fba17991e63b00ed1d2db53aedafded02dcd3cd632238`.
- helper-final-admission/source-review-v1.json: `3e167e5f4a4080b99da6e993dfb8b793656753a57bda0835f409416e107e9130`.
- helper-final-admission/process-observation-v1.json: `c101134833a557d5eb0399fe4b38f7b25e98777fffdc7cd7f7aa664024cc2d7c`.

Discovery command-adapter evidence (private receipts; focused current-candidate observations only):

- discovery-command-adapter/baseline.json: `815d88f37cd45941e93813f5737c7216b2f58c8891c56549bd61d7c03c0eefd9`.
- discovery-command-adapter/build-v1.json: `32cab3fd6d4c2fee835b8b35e4525f9345d22ff326d5320a4896cf809a5cb6eb`.
- discovery-command-adapter/build-v2.json: `e43348d1e1b795f3adc0babc22b52638d9e613fd3810e12cf2ccff57a7b462a4`.
- discovery-command-adapter/production-build-v1.json: `6f958b47be1c41612196f328b72f3a2a4977fe7b18dc118b6812cc2c311cf136`.
- discovery-command-adapter/tooling-v1.json: `bc37e7f41f716d072f750e8c545d58ff08794387a05d31cb6068e2e0cbb7e5f6`.
- discovery-command-adapter/tooling-v2.json: `0a6a3e43870274e4af81b612e0b52eadb7dfcba417d8ed91416c2ccd6cab274a`.
- discovery-command-adapter/review-v1.json: `7995a93296d6e6bded575f91363e97df643d36901cfad0da098c000895462a64`.
- discovery-command-adapter/source-review-v2.json: `d5973a9afa483c11497243fb97e4df3d1f29a7271fc5e2da5eb7585dde68fc7f`.
- discovery-command-adapter/native-transport-v1.json: `65297be86427af249c03a32ca276cd28d2c39198775ae0663525b9ceb3ed7cf1`.
- discovery-command-adapter/native-integrated-v1.json: `f1900f779b96778e2632be6661e53e113a728d7ac88012e3c48d3a0d8fe2cfd6`.
- discovery-command-adapter/identity-v1.json: `c44fd07e255abf0b6ebe3914213b1f831ce2787815c54dc2b84e6dd13cb96409`.
- discovery-command-adapter/production-exclusion-v1.json: `1f044c8441f535e16ad44d455f79e131baa5a795643966bc2895cec1a9cc9117`.
- discovery-command-adapter/qualification-ledger-v1.json: `1a8c7579f7ded06b9a6d81ea36649428a1ff90fdad74f336f3d319f3b7f031e1`.
- discovery-command-adapter/process-observation-v1.json: `c288bddccfede9f09ed1db31d3f5ced6184becf320f12f5832e1db3d5813496d`.
- discovery-command-adapter/cache-cleanup-v1.json: `a4ea494702263e6fb1e64434ae2bb12c6d57e20342112c84a1a2f55594f4396f`.

Discovery trace-custody evidence (private receipts; bounded component observations only):

- discovery-trace-custody/build-v2.json: `f4ba825c5723f3458392a93218c40c900f1cc8b482693ce12feef8ea6dc20e9a`.
- discovery-trace-custody/production-build-v1.json: `db1255cfa243f61218a49100f7afb9ee2b275e8b73486d409d539aeca082b0da`.
- discovery-trace-custody/native-transport-v1.json: `f831944f7219d845924d2dae11a0725cb398713d93fcc66bc4d7e3de69119830`.
- discovery-trace-custody/native-integrated-v1.json: `cad2b9bf30c4c8d1bdf7f0ebe3c74a131e000e9a2eca320d71b45062070a5804`.
- discovery-trace-custody/tooling-v1.json: `36d7adb87cd1dbb4cc4b1982f99b3dee2bb0af8c3ad2b89089127e58b396368e`.
- discovery-trace-custody/identity-v1.json: `30de10f367e6eff407516df99b67c84ee556e9370cec00b4cc26c6dbb0c24502`.
- discovery-trace-custody/production-exclusion-v1.json: `b4dda762a70e18af299e6bc46ea511151862366341f672fcb0ac3cabeb7efd18`.
- discovery-trace-custody/qualification-ledger-v1.json: `34060ac3744d8daf87dc077f242606a5b16463fc39055d0c91dd02eab2e2feb9`.
- discovery-trace-custody/review-v2.json: `f9e37640b72a523ab93c6acc0a05970f8bd26c6980c21deb1c91ee41c91618b6`.
- discovery-trace-custody/review-v3.json: `f1e55a68ee2ec5ddc8ed0a3efe634e41557b1d8d0d27f93d1f7c14c3b7cd6252`.
- discovery-trace-custody/process-observation-v1.json: `db62c6f67561cd214f34dd91ba19acb9804fae92917b3242ea2e3c2b70d4dc07`.
- discovery-trace-custody/audit-correction-v1.json: `c54d9045e6b53400360a4fd3fb3bcacf4cd23b213639b4771b49700f77294d30`.

Read-phase component evidence (SHA-256; private exact-source receipts):

- Read-phase `build-v1.json`: `7115b2b7f728601952897f1db196dd22292b83e8afb25d83a9d2afb56a949780`.
- Read-phase `production-build-v1.json`: `faecef5f39f8b3f4c53ca48e8be2ea6a1ffdf0419c567aa466f91a2618120d7c`.
- Read-phase `tooling-v1.json`: `638a6495a2af12e9b9d264ef464f850bcf5daa9e495a5196898b63414b586163`.
- Read-phase `identity-v1.json`: `5491ec70f1da994e6b2fec40b02026e44888ced1d8a09038317583c3f78bd379`.
- Read-phase `production-exclusion-v1.json`: `9929a90745e2e617a735f5d1e5da7482914973705139d5546dc8eadf8073280b`.
- Read-phase `native-transport-v1.json`: `911fd924424cfe2d3bf7299b1a4955a72e335ca755152f95fcbe0d249d9a00f2`.
- Read-phase `native-integrated-v1.json`: `a5e877a07f206e05fd319964e31d7ccf4f5c24e8b65f3738a39c881d7e2fd302`.
- Read-phase `qualification-ledger-v1.json`: `d13dc8cbe01a5f11bb6357bd93ef380a434545d64bc03718c0a60975e1020eda`.
- Read-phase `source-review-input-v1.json`: `b8d3485e0ba288e2034e464e725228ba674251c7e8745243097c7c37fdeec4a4`.
- Read-phase `executor-review-input-v1.json`: `71ac7c07777fcbd7ba71805db0f6b958f0935647f65d539adf8251dcfdca8f42`.

- Sealed-policy transport `build-v2.json`: `3e75b38444396cd6f12cf0384c2814a0273313d33276ca108e77de96917fb464`.
- Sealed-policy transport `production-build-v2.json`: `3be53cccacc1ae6127e7b711769cb73c08963f114441c505c1e664d827021120`.
- Sealed-policy transport `tooling-v2.json`: `294ae4e0a703cbc833be946e1c3a323f8056e0be1d91b0bd8d617422664823f3`.
- Sealed-policy transport `identity-v2.json`: `f39819a872e952132195e1784244ed3a1a27910d272a21f012a4d49ba1632a91`.
- Sealed-policy transport `production-exclusion-v2.json`: `534e85c5d9ad4825edcd5ba51a4d06f48e4f2c9da7bd4e47420c57475062473a`.
- Sealed-policy transport `native-transport-v2.json`: `d6dd873df01ee5e060c3f280ebbbc99d890f5893ddb4297f852c7904bc61d7f7`.
- Sealed-policy transport `native-integrated-v2.json`: `dd44c374d916e8c1bef03a00bf4dde0d7e5a6ed516be7cd645f3e5344eb2f949`.
- Sealed-policy transport `qualification-ledger-v2.json`: `2c8dc394adfe80d8dad2bf5218406b82df5106368e27d7eb3caa2bef762a7cbb`.
- Sealed-policy transport `diagnosis-v1.json`: `8b1c86c06745faead8f4bdf7bdf5600c9874211eff70bae4d75a3b9b3ffd53da`.
- Sealed-policy transport `native-integrated-v1.json`: `cdf1c6a52de3da8b09943169e3d753f6dedee22629b565568573c6a0c15948ce`.
- Sealed-policy transport `source-review-input-v2.json`: `13c18403b0074817ea0f453d43834488c3390ea5738faf6e18ee47b085acaae0`.
- Sealed-policy transport `executor-review-input-v2.json`: `3af04ec32160bc37ab1d48a461b55acc24d967bede72f2111ff338d03d8a26f9`.

Production-policy custody component evidence (private exact-source receipts; prior failed attempts remain failed):

- Production-policy custody `build-v4.json`: `d8fede2393a3802cf1b935e19dc157540fc26c7ddb6e7bc2357a64bbbedf4bce`.
- Production-policy custody `production-build-v4.json`: `fe483907d0efb52949740a2bad0a3a8afa9050182ed0154896d9be5199631137`.
- Production-policy custody `tooling-v4.json`: `846a00b326e18614e41aeb18eb0414be08a96092c1fa42c9bae2520034ade561`.
- Production-policy custody `identity-v4.json`: `905660908f89f58212b71ef108f25ce857ebb9c8e2c13de8b9ea9e0264431715`.
- Production-policy custody `production-exclusion-v4.json`: `1143b6190a1437f35bbfe4e539b9d49a014bf14f9ca10baa8ebc369103610e73`.
- Production-policy custody `native-transport-v4.json`: `7a1e177fe3e2fec1038c97f7134b81e49cfbd78c6c6b6b7e8862ba57585407f2`.
- Production-policy custody `native-integrated-v4.json`: `0272c30a932eabc0b491d1beb3840553ffb3fc8a061b07abb5ac5e26556e0cd6`.
- Production-policy custody `qualification-ledger-v4.json`: `1bd18e3a83e9db962ddb955174365710d4b630e8a7110da1e5a8f9ce3065a8e2`.
- Production-policy custody `review-source-v4.json`: `599f8049ae47c767f26ae92cadffe1369bda9f9b033e95fa189101e503eb9a4a`.
- Production-policy custody `review-evidence-v4.json`: `c04c5653da4ea3587ce942be5f6d39899ed98d00d970d5e038668ac99edf2a44`.
- Production-policy custody `diagnosis-v3.json`: `f8e53f402d0cfe3974a2036c4920186aa0eb80d461bc35e366318a50662de3ef`.
- Production-policy custody `native-integrated-v3.json`: `284dac9a70c71353d42e0838cca6acc3697345d37c9cb451f94f90efca0f820b`.
- Production-policy custody `source-review-input-v4.json`: `2b94ea4df7fc7edfe4e8c9dc965d4f9940019fb1eba606ea49eb0e9123c592fc`.
- Production-policy custody `executor-review-input-v4.json`: `880fb37314c552dde3989ad2adda106e4b9da8be7293ad5fc8bced1be4b07423`.

System-config custody diagnostic evidence (private exact-source receipts; failures preserved):

- System-config `build-v1.json`: `27e436f884d38cff749455125ac2fd05b1459dec81a2a716b86350fdf3bc45b8`.
- System-config `build-v2.json`: `5290ba41362a0251251d41fa1d1c356297a0151af72c112900d69399ba706c13`.
- System-config `build-v3.json`: `6a3348ab11aec09582d88e0da317636d28990c9dda85efc75497585bdeb69c45`.
- System-config `production-build-v2.json`: `27619f9c32d50602f70511f83be17551213fb193e27df89d27d0269ee7504940`.
- System-config `tooling-v2.json`: `c6a49b6c681ef9286bd780f0c1488d00100b93dc20ca9aff918899edf3cf4445`.
- System-config `identity-v2.json`: `90f8ac740b2f26badd6a3a8e81787df1a8c15ff9c70100d5ed56513d47138b5a`.
- System-config `production-exclusion-v2.json`: `5ffbc4f07ce6d17cc9b3772b7299ffd3f78c4b5ef092205ef35f6bf7a3875038`.
- System-config `native-transport-v2.json`: `08207677e1604c3959718d5434bc84a361314bcbb6d06d146d52c7cddb521518`.
- System-config `native-integrated-v2.json`: `893e812f3821089fbba2fbddd72a2e7aa68dcd0f91d7a47f859ecf3e712f53ad`.
- System-config `native-transport-v3.json`: `5801894c823e9f827629a88dc1ec11961d094c9acf168ea1e4d823fd2fc80957`.
- System-config `native-integrated-v3.json`: `952753f82329bc8c88335cb07edeb6f1c463aa08f46d00f91af6fb259cfafd81`.
- System-config `diagnosis-v1.json`: `d0d4ce0baa389e6b366568656ffe124000a58ded143c7c70c6935b7e76a1c0f9`.
- System-config `diagnosis-v2.json`: `1051aa1c118fa41792af3f0a08aa9b1e651fcc6a501e7e021fc0349646185a8e`.
- System-config `diagnosis-v3.json`: `24d6ae89bcdda5e00bf3be19574d1d23c7519efe3c46e239a3c669e563052c7b`.
- System-config `review-source-v1.json`: `46dd65a7a131fa2a707274146c3ae846f40e8bffd96ea51f1db4c13818c9f7f8`.
- System-config `review-source-v2.json`: `9327dbed2d0cc343b9ea17d64eca0f5593669d3b6cfb60c7136f88ba4f5f5251`.
- System-config `review-diagnostic-v3.json`: `4ccc6c38e5aee1f78b0f2078a8983efc36ce9957bba2b3a4ba17b6f65ee38df2`.
- System-config `review-diagnosis-v3.json`: `aa0cb8d109b74dfaa23c51f93446f656c31b673a7d4f8cc15aa78c3448e95e70`.

Registry ordering correction evidence (private exact-source receipts; bounded qualification only):

- Registry ordering `build-v2.json`: `124c7216c40f5568c73ac3a756c38e820bf6920951da4dcc7117b954b5099d4b`.
- Registry ordering `production-build-v2.json`: `8ab377bd00c0ed29cc62891874b44937904091416f05c8921ec3e6c4b0e9c9b0`.
- Registry ordering `tooling-v2.json`: `af311f3be9a2c0828d8852c55f27ac981c55ea9d29a5efbcdee3339066b303c3`.
- Registry ordering `identity-v2.json`: `341eef55500a586db1905b716b3c62fc6b6f938dce1fb609e6f1313cf94fdc4a`.
- Registry ordering `production-exclusion-v2.json`: `b4363f56ee69f1698807313f1b473357c740fda2684511f7922e3a7074c4499e`.
- Registry ordering `native-transport-v2.json`: `995e6c2e5f0c009cb3c236c5d6451ad3474f9899d5cf894af30caed654036fce`.
- Registry ordering `native-integrated-v2.json`: `8ed42dbbb486568b9e59e2863c543590e46f575f35e2f7209ea43a409416daff`.
- Registry ordering `qualification-ledger-v2.json`: `a0bf9811b2b3f579f339c07a9f7db3cd08fbc46182bf8803c44c8920fe06ca76`.
- Registry ordering `review-v2.json`: `60f7c35e03f2add5fb56e94d2c7ad30e62ec8e8053c919fe4e5489911ed0c04b`.
- Registry ordering `source-review-input-v2.json`: `6815d3b9048f7ef9ffcc8ad9c664a0b36c76279044f79e8ee48cee65ff79c45d`.
- Registry ordering `executor-review-input-v2.json`: `63edf04c6182ac22dd061294e40bd559228c1a851594c0f8a8dd266a743ae82d`.

Selected-operation diagnostic evidence (private receipts; no full-candidate qualification claim):

- selected-phase-rebind-v1/build-v2.json: `71a476d809a6fc996693dd1d8a8147ad1181ca41461851874bcac0cc6451655a`.
- selected-phase-rebind-v1/production-build-v2.json: `b713a5ae9fbd292c0579a3212223f4fe08be3a4fbf4d5de35e7f4239820b8dcb`.
- selected-phase-rebind-v1/tooling-v2.json: `a73d3feecf962436e503c0acff2850c86227aea7a67f0be24bdfe8e519d5cba7`.
- selected-phase-rebind-v1/production-exclusion-v2.json: `b2dabdc0e3f222b486101e1daaed4a321b0eacd27c9a940e752daca8a88c0642`.
- selected-phase-rebind-v1/native-integrated-v2.json: `4dc877e19eb750c5d9eda0137d5b1fcd288e354e4b36cff4b7f2bfd9f7fd06d5`.
- selected-phase-rebind-v1/build-v3.json: `02288d083a28cde714b6192be91e34ede22881191f13c9987f1845d934fdbba7`.
- selected-phase-rebind-v1/native-integrated-v3.json: `2caa4268903f585a277c78ea4aac492ede31387bbd9e7001bca46aa0b47d2a02`.
- selected-phase-rebind-v1/build-v4.json: `f64826f5cc1df2ace45a90510de66156a13c0b51b5dc6086eb621d09abc59814`.
- selected-phase-rebind-v1/native-transport-v4.json: `41100fef203944238cba8b7fb03d9025e13dc3d7ce5fd8981d33684c20a43c33`.
- selected-phase-rebind-v1/native-integrated-v4.json: `90803a7da9520aef057df79ec753e7dff700318390df103d888384e2c69de692`.
- selected-phase-rebind-v1/diagnostic-v4-input.json: `d1e709c3599b3848b34154d548e9c929892f2f3977a5d27a0a264e0c38e31f29`.
- selected-phase-rebind-v1/review-v4-diagnostic.json: `5cc59f9c630cb6c984ed05fe6766c54a57bb0e398eb7903f1574adffcaee8b1c`.

Selected-operation correction evidence (private receipts; exact bounded observations only):

- selected-phase-rebind-v1/build-v5.json: `fa159ff70a0353939af0c108ac9ee08613f94e6ae98a9358006b9af4bcfbd5ef`.
- selected-phase-rebind-v1/native-integrated-v5.json: `4d5015dbd1972e1ba8d8d3bd9b002506b261e4b9953c737cec06e6eb842dd793`.
- selected-phase-rebind-v1/build-v6.json: `af8e23267f745bbf3eb37c10cb1be345afbd444d59f14e35ea3bd395a55af621`.
- selected-phase-rebind-v1/build-v7.json: `541584947ec8bdc98179a305da001c9fbe3bcac864db9a035e9b22b11c9fd7d4`.
- selected-phase-rebind-v1/production-build-v7.json: `29319ace8f4fb17197a73aee58c4fbd0226727ae635df33c62cd9ecaef6ed112`.
- selected-phase-rebind-v1/tooling-v7.json: `8285bd1b7e9e26fec17e2e5c52224c497f8083ffff4c88f78bfdab95579585e3`.
- selected-phase-rebind-v1/identity-v7.json: `9688ed02c8b87dd3c7b62b1d40367649f61b4dc1ac704d1997320726d9f9533f`.
- selected-phase-rebind-v1/production-exclusion-v7.json: `43a2695d9e8dd7a31447e645ff7c2bdcedd3f558c17cb446c3e217f8d1d82210`.
- selected-phase-rebind-v1/native-transport-v7.json: `5b265275136ddd7b0e1fa0c2e3d33b200547486f0d503b05ea62e78260a78193`.
- selected-phase-rebind-v1/native-integrated-v7.json: `9248dcb181f0ffd72f79fb7fccab88d5fa0ece5f8197081fb6155e278c11d408`.
- selected-phase-rebind-v1/qualification-ledger-v7.json: `82935458613859ea2c65d5da38226da0ec54eb461b57f16f535fa3ed373ad852`.
- selected-phase-rebind-v1/review-v7-correction.json: `9dc68cf509e3b7ca012b36ee96f7d531d4031ccd78a2698a3a88a590e945a56b`.
- selected-phase-rebind-v1/pr47-delivery.json: `ecb3ad2df12675e20da3bd94aebe4aa84fdeb0ab9f45d9fac09d1741cb322d78`.

Configuration-caller/capture evidence (private receipts; bounded observed outcomes only):

- configuration-caller-build-v3.json: `21280ca552431517be1c8f4b61463b9f776129be426da9fa92290f8b6d4ed092`.
- configuration-caller-execution-ledger-v3.json: `2228be6dacc3ec3e2d82c02e59ed7c1a957a925e7f7a44edc321b2663ae92cc8`.
- configuration-caller-evidence-review-v3.json: `23a05fa104f56060b6ea6c369ec90d86223b9704f011c590308d057ecb28c064`.
- configuration-capture-build-v1.json: `809bbfbf621870d94fa0fc36359dfa1bbc98981310e33d815ff6f09e0215fd26`.
- configuration-capture-build-v2.json: `a47e851e1ef1e46117b458754d26ab883657e0d57dd22138626898ef772fc4d7`.
- configuration-capture-build-v3.json: `9f6c68aa49304ee95a729e0f3c023f176a45ce1a3017bfb65894911df6089152`.
- configuration-capture-production-build-v2.json: `afd14474ecbaa3925a58466fab26ca414df4008e131c00eafc6a35a2256dfa17`.
- configuration-capture-production-build-v3.json: `698347f56861d332dbcdd097a1143fe7a5de3631a8a838ff6e7784e297bb46e7`.
- configuration-capture-production-diagnosis-v2.json: `f1b77de974013b8e9e2322a2dc2a689411919d4d9927ceaa89b7e4959450797d`.
- configuration-capture-production-repair-v3.json: `44a3b190975b4296b84afc10b83b646b0f71a1c979de89e8a7558a663bbdd3ed`.
- configuration-capture-tooling-v3.json: `27dee403d11c7b47a584cc23e5ff16100b91f93c27e39b845375756e6b48ebef`.
- configuration-capture-identity-v3.json: `2fb479e73265e0eee5e19392ae6788aa4c1cc1e5554fa6449c022f7af1c0c53c`.
- configuration-capture-production-exclusion-v3.json: `c94c193abda2949aca10d31f1f1e31b944d0f9e4f46c99d50da14d41fe189bbb`.
- configuration-capture-native-transport-v2.json: `95a40dfd4db2215e53e7a7158a1e53ddcfb817cb994d5c67de6e228047f69e13`.
- configuration-capture-native-integrated-v2.json: `c455bbbadd35f92b4c92343dd4349f7bc4dd2800121c98a77bf79340ab2f9ad5`.
- configuration-capture-native-transport-v3.json: `91d49cef3db6adbfa4b36cccb5c5591b6ccd972f6ae1b6123d99c3c5b63fbe30`.
- configuration-capture-native-integrated-v3.json: `0c9b29903761f08f50192caba4cac83791e1d77d729679b215d94bb82bdb45a1`.
- configuration-capture-execution-ledger-v3.json: `5dbc411ff5572c2ff77d0eb4ce5a8c50d938d1535434fa014aa3cb39a8447301`.
- configuration-capture-review-v1.json: `f2a81755972446f10b60fb1ab5f517986d2d0302f753bef8cd63a06f9008a3ce`.
- configuration-capture-review-v2.json: `5b26a33962518def5d055375f0b95f865f91e32f1dd52905ef18ac8d7c73a10c`.
- configuration-capture-review-v3.json: `868ede3119640d26534eb3fb6b805f82d5a29357b93071ad4061917ae4bb3121`.
- configuration-capture-evidence-review-v3.json: `391fe39ae424bd98adf61edb50d2171f8a84ceb54a4f1f451945dfbd5e8e03e4`.

Inspection-admission evidence (private receipts; bounded observed outcomes only):

- inspection-admission-parent.json: `d94e4d44b73c5d6f19b00535591ae1fb735649938537cdc41666c065973c58fa`.
- inspection-admission-build-v1.json: `e33e0bac519d1ea2ddeeb1c64cf4d053d4af4bda343b6dba50d89657542cec50`.
- inspection-admission-build-v2.json: `228a4ca90c81824025101b6c450884ee9965503fdad3d2c33874cbc083c6baed`.
- inspection-admission-build-v3.json: `d3914f1793889ccaf7cdc38b9218a6d1e213ebf11934fd340238101004703af1`.
- inspection-admission-production-build-v1.json: `78088f4bdbf28a3154d37c3974e5b868462b22f243bd1a76a7cd8d28598c148d`.
- inspection-admission-production-build-v2.json: `99b49763a106adb7ade6c5605c625ef13508f7594b2918c7926f3634dcb41440`.
- inspection-admission-production-build-v3.json: `f6049defae0dcf9db99680239f750e8c4c0f7c9fe56f034221361a8291cb65f7`.
- inspection-admission-compile-repair-v2.json: `2640958eb451c926192cce36c3666ed18063ff1d37e43ba42630b0e13c844380`.
- inspection-admission-planner-repair-v3.json: `ee25a754c573409dcbcaa218e1bf2be117a8971ef1fd99fe9b390a225087ca70`.
- inspection-admission-review-findings-v1.json: `18cd1e26ab1325a0477a4cb33adbcacd2613a60029654322b0cfddbb201c235a`.
- inspection-admission-review-v3.json: `8cc5874c6bd45def7a1b848ac670cfc900ffa2a369ebf0384eb58f6783597f54`.
- inspection-admission-verifier-review-v3.json: `8c35c4dbe1b3973f3a6bf90500d7fa92ab2e9fb771f37d4c901002aa4d83e987`.
- inspection-admission-evidence-review-v3.json: `9e590d5a09443bc7f9bca509b978de041cc5cd1e8c55fbad0eef46053e196480`.
- inspection-admission-tooling-v3.json: `c84ead6b8b3fee6e0ffec95c0ce235720f1f0a1b60b971ba1df472b7b0e9db36`.
- inspection-admission-identity-v3.json: `d32184470d547119187aa49fe9464bf8e7aaade0e93e89513d297a290b808c8f`.
- inspection-admission-production-exclusion-v3.json: `72a601642aae8f4ab9661e0d6f2e15b8fec7e5aa590fcca105703de66deb815d`.
- inspection-admission-native-transport-v3.json: `d238b8d6c624d4deb114630ebde4e625bef73578703dd0d0b2940fdc12edab79`.
- inspection-admission-native-integrated-v3.json: `5b772f8c9cbf2c9bf4c527f7bb69819d20645593def9df007cb6d75e3ee12be2`.
- inspection-admission-execution-ledger-v3.json: `9f6a3277e278a1c4447049d7d3351abddab9542d5ed2e6daf123f586dc7085b3`.
