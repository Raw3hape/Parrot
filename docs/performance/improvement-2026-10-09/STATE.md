# Resume state — primary release installed and validated

Primary M5 Pro64GB only. User authorized implementation, comparison, verification and installation. Secondary Mac unchanged. Entry: [README](README.md), [rollback](ROLLBACK.md).

## Authoritative evidence

- Installed/deliverable main SHA c1c3aacfb66bae5768f6593d5ca466a0a0d7ce43712e2b433422f17c96746302; preserved Apple Development identity/Team5C2PL8729F and entitlements. [Signature](evidence/release-final-signature.json), [install](evidence/install-result.json).
- Exact installed10-case gate3/473 errors vs Whisper14/473; RU/PL/EN unchanged, mixed12→1. Timestamps and child exits passed. [Gate](evidence/quality-gate-installed-result.json). Pinned production selection references gate SHA94ba40e4670ca87edbb7fc4856a6be006e1ad9b426cb5d7107b3f1090c181ac5.
- Full suite258/0; helper13 pure checks; real nonblocking pipe/cancellation/exact child-exit regression. [Tests](evidence/release-full-tests-pipe-repair.log).
- Actual capture/offline clone passed. GUI Stop, immediate Quit, ordinary menu Quit, playback, Final/Live, starting while final pending passed. [GUI](evidence/gui-workflow-result.json).
- All6 own QA IDs have hybrid Final and explicit Parrot QA titles; private audio/room speech retained. Original88 IDs/meeting data and21647 raw segments unchanged. [Preservation](evidence/history-preservation-result.json).

## Limits

Synthetic corpus is not universal meeting accuracy. Hybrid costs more post-call time. First corrected signed pipeline68.368s includes load/initial specialization and concurrent build/Whisper warmup; final installed warm ten-case run43.730s. Mixed-long Whisper outputs varied; it failed batch-equivalence acceptance. Monolingual EN batch control had identical outputs and11.1% median gain.

Physical status-popover Quit could not be driven by CUA scope; deferred close/terminate order passed a regression test. Actual ordinary app-menu Quit while capturing passed. Existing9B guard10GiB unchanged; ASR guard6GiB. No new secondary-Mac proof.

## Source and lifecycle

Pre-existing dirty optimization work preserved/integrated; no reset. The installation run ended without commit/push; the user subsequently requested documentation and Git handoff on 2026-10-10. [Git handoff](../../GIT-HANDOFF.md), [evidence index](evidence/README.md), [seal](evidence/release-seal.json). Exact source snapshot and pre-task/source patches remain local and ignored; the original seal describes its own capture time, not later Git status.

Temporary build/model/corpus copies are cleaned after validation. Keep latest signed app, rollback+DB, private QA, helper portable build component and small evidence. [Cleanup](evidence/cleanup-result.json) is the resource handback. Do not restart finished jobs from old checkpoint lists. No goal tool was created.
