# Native desktop acceptance

Status: required, not accepted. The public repository is still preparing its product-source import. This runbook defines acceptance procedures; it does not establish that an installable product or any listed acceptance result exists.

The operator records the candidate source/artifact digest, version/build, supported Mac architecture and macOS version, tester, date, expected result, observed result and explicit pass/fail decision. Keep identifying host details and raw screenshots in private evidence. Source merge, automated probes, signing and installation do not imply physical-input or product acceptance.

## Preconditions

Use only a separately qualified candidate and disposable repositories/state. Complete the applicable safety, policy, installation and update gates before an installed test. Never use an existing working repository to manufacture a dirty, diverged or cancellation scenario. A test selection does not establish repository authority; use the fixture policy and approved authority setup. Do not enable source-bound installation or real-inventory automation to run this checklist.

## Dirty-after-selection compatibility scenario

This is a retained behavior scenario from the existing application, not approval of historical screen layouts or an old script. Prepare at least eight disposable clones from an approved public test origin in one temporary fixture root. Give the first sorted clone the name `00-dirty-first`. Establish only fixture authority, select the rows and complete review while they are clean. Before starting the update, create one harmless untracked file in `00-dirty-first`.

Execution-time revalidation must classify that row as `SKIPPED_DIRTY`, with a truthful reason and no Git mutation in that repository. It must not become an inspection failure. Cancel while later rows are active if the fixture workload permits; otherwise record cancellation as untested and run the dedicated bounded cancellation fixture. Confirm started work settles, owned descendants exit and later rows do not start. Inspect the current report without editing it to produce a desired outcome. Preserve the untracked file and all pre-existing Git data until the evidence is recorded, then remove only the owned disposable fixture through its normal cleanup procedure.

## Physical desktop checks

- Repeated keyboard shortcuts and menu activation reach the same intended window; duplicate activation creates no competing operation or authority.
- Selection, review, Back and Cancel preserve intent and do not grant authority or start work early. Protected or incompatible-policy rows remain disabled before repository access.
- Hide/reopen preserves current progress. Cancel and Quit drain owned work and children before completion; stale callbacks cannot reopen windows or admit new work.
- Ordinary target dismissal clears only its own obsolete foreground feedback. Unrelated errors and the contention recovery rules remain correct. Check visible text, tooltip and VoiceOver help together.
- Inspect minimum and larger supported window geometry, light/dark appearance, keyboard focus and VoiceOver navigation. No automated screenshot or metadata probe substitutes for these observations.
- History and reports remain read-only. A shortcut collision has truthful fallback guidance. Startup remains opt-in through normal macOS Login Items; test logout/login only after the installation gate.

Record each omitted or unavailable observation as open. Migration from the legacy installation, signed installed updates, recovery and compatibility retirement have separate runbook gates. Acceptance closes only when the operator explicitly accepts the applicable candidate and recorded criteria.
