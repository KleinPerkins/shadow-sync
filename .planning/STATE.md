# Authoring state

- Repository key: `29e9090a-7b77-443d-b953-9b1deef3bc60`
- Lifecycle: active implementation
- Accepted project, requirements, and phase scope: [phase plan](artifacts/PLAN-29e9090a-7b77-443d-b953-9b1deef3bc60-25769985-feb8-5809-8833-b30f202730f7-v3.md)
- Verified documentation baseline: PRD v3 (37 requirements), PLAN v3 (15 phase/work packages), seven approved ADRs and the publisher-resource specification merged at `06772fc791df457f778265c092031f6402e1201c` ([PR #6](https://github.com/KleinPerkins/shadow-sync/pull/6)). The corresponding doc-warden delivery observations record this commit without changing frozen authorities or their original receipts.
- Verified tooling component: deterministic shard planning, source binding and evidence validation merged at `a15f01aafc1922bea0c108433acbbfd15da7541f` ([PR #7](https://github.com/KleinPerkins/shadow-sync/pull/7)). All 84 tooling/readiness tests passed in the [exact-head PR run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41634564668) and the [merged-main run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41634896124). This is component evidence for REQ-GV-06–11 and PLAN v3 P3-CI-02/03; complete application registration/execution, hosted transition/routine coverage and the ordinary reviewer-App merge canary remain open. Protected administration merged this component; no ordinary App-merge claim is made.
- Verified native-report component: the closed AppKit report contract and negative tests merged at `42197baf509c9cacefa09277471feed01e22c10c` ([PR #9](https://github.com/KleinPerkins/shadow-sync/pull/9)). All 98 tooling/readiness tests passed in the [exact-head PR run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41638373567) and [merged-main run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41638519182). These checks validate report structure and reject incomplete results; they do not execute the application or establish native acceptance.
- Historical private candidate runtime observation: all 35 registered executable suites and 311 expected case groups completed successfully, with source/binary hashes bound to the receipt and no new fixture roots remaining. The run used disposable fixtures with the real home and external network denied. This predates the current 198-file candidate and is not a fresh full-runtime qualification. It is local-toolchain evidence for an unpublished candidate; it does not establish hosted CI, minimum-OS support, a product release, installation, or UAT.
- Accepted native fixture design: [PR #12](https://github.com/KleinPerkins/shadow-sync/pull/12) added the fixture contract and native acceptance runbook at `d16532586792be2d309036de5a587bd34672f826`. [PR #13](https://github.com/KleinPerkins/shadow-sync/pull/13) adopted the process-limit successor at `654aa0c8a098c70e6d49826caa471c0c4c5d4483` after the attempted nested sandbox was refused by the platform. Frozen predecessors and failed evidence remain unchanged. The successor preserves fixture-only isolation, bounded lifetime, ownership, reaping, and fail-closed qualification.
- Prior 196-file candidate native observation: all nine M5 AppKit runs completed, covering 133 mandatory case groups including three latency trials. Every run verified isolation, child reaping, helper cleanup, and fixture removal. The helper qualification passed all 15 required cases, including actual parent death, lease EOF, lifetime expiry, malformed arguments, and termination behavior. Exact source/binary hashes bind these results to that 196-file candidate. They have not been rerun as full current-candidate qualification. They establish this native component only; full native-route registration, hosted CI, release-toolchain/minimum-OS qualification, installed behavior, and physical/visual UAT remain open.
- Prior 196-file candidate tooling and production exclusion: all 267 tooling tests and 24 fixture-contract tests passed. A separate production build excluded all 81 registered testing markers. The local development toolchain is not the accepted release-toolchain qualification, and the build is not a signed product artifact.
- Accepted production ownership correction: [PR #15](https://github.com/KleinPerkins/shadow-sync/pull/15) merged the specification and audit projection at `287d455506bdf8a0fd5d5b38cf84cf152854b818`. Both the [exact-head PR run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41666687452) and [merged-main run](https://github.com/KleinPerkins/shadow-sync/actions/runs/41666996158) passed all 98 tooling tests. Doc-warden reconciliation was conformant at that merged revision.
- Prior private 197-file candidate foundation observation: all 16 M4 ownership case groups and 267 tooling tests passed against reviewed source; its production build excluded 95 registered test markers. This established OWNER-01 component evidence only. At that revision, production callers were not integrated and all five audited findings remained open. The exact receipts and preserved failed attempts remain historical evidence; native wrong-parent/borrowed-adoption refusal coverage is still required.
- Current private 198-file candidate runner observation: CancellationToken, DescriptorProcessRunner and ClosedProcessRunner now share the same direct-child signal/reap owner. Independent review found no P1/P2 in this bounded change. Both affected executable suites (50 expected case groups) and all 267 tooling tests passed against the exact source; the production build excluded all 104 registered test markers. Both new actual-runner tests preserve an unreaped child while cancellation is paused before signaling, then verify exact terminal status and refusal of later signals. An isolated negative control that restores the separate raw reaper while suppressing termination signals failed both exact ordering assertions, with no timeout, leftover fixtures or lingering test threads. Successful runs denied real-home and external-network access and reaped their test processes. The preceding integration revision passed six regression suites (85 case groups); only testing-only timing and wait diagnostics changed afterward, so that broader receipt remains revision-specific historical evidence. Failed compilation and earlier control attempts remain preserved. This corrects the audited token/two-runner signal-reap race only. Two P1 worker/borrowed-child findings and two P2 cleanup findings remain open; OWNER-02/03/04 and native wrong-parent/borrowed-adoption coverage are incomplete. Fresh full 35-suite/319-case qualification is still required. Local-toolchain results do not establish release-toolchain/minimum-OS qualification, hosted application CI, installation or UAT.
- Production ownership audit confirmed three source-supported signaling/reaping races and two cleanup gaps under **REQ-SF-05**. The [correction specification](artifacts/SPEC-29e9090a-7b77-443d-b953-9b1deef3bc60-81b2dc00-4f47-5a79-be4c-519eea5ce71f-v1.md) binds the direct-child owner, complete caller integration, exact borrowed-child custody successor, and full qualification gates. A shared owner alone does not close these findings; no live PID-reuse incident was observed. The earlier SF-04 reference was incorrect: SF-04 governs the external matcher.
- Next action: complete the remaining direct-child caller and bounded-cleanup integrations, adopt and implement the exact borrowed-child custody successor, and qualify the complete correction; then finish native/fixture registration, fresh full-runtime qualification, reviewed public source export, and hosted shard/transition/aggregate/reviewer-App proof.
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
