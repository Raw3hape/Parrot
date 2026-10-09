# Evidence index

This directory preserves the accepted primary-Mac release and earlier attempts. Start with the final aggregates:

- [Release seal](release-seal.json), [signature](release-final-signature.json), [installation](install-result.json).
- [Exact installed quality gate](quality-gate-installed-result.json), [declared corpus](../../../../Tools/qa/quality-corpus.json), [installed case results](quality-installed/hybrid-results.json), [Whisper baseline](quality-whisper/whisper-results.json).
- [258 tests](release-full-tests-pipe-repair.log), [production capture](release-production-capture.log), [offline inference](offline-result.json).
- [GUI workflow](gui-workflow-result.json), [original history preservation](history-preservation-result.json).
- [English batch benchmark](en-benchmark/summary.json), [mixed long benchmark](long-benchmark/summary.json).
- [Resource cleanup](cleanup-result.json), [source manifest](source-snapshot-manifest.json).

The ten cases are synthetic TTS. Benchmark transcript text belongs to those declared fixtures. GUI/history results retain only metadata, counts, fingerprints and outcomes; private meeting text/audio and QA manifests remain in ignored recordings directories.

Earlier result files are dated attempt evidence. quality-gate-installed-result.json and the main hash in release-seal.json select the final accepted build. Do not substitute a prior candidate's gate or claim that source-only, portable-protocol or unit-test proof establishes installed inference.

Local-only originals: source-snapshot.tar.gz (SHA in release seal), source-working-tree.patch, pre-task-dirty.patch, hybrid-first-case-sample.txt and large build logs. These files are deliberately ignored by Git; their links in the release report are usable in the original workspace. A fresh clone obtains code from Git and follows [BUILD](../../../BUILD.md); it does not require those local debug artifacts.

The seal and manifests are immutable historical evidence. Documentation/Git handoff on 2026-10-10 is described separately in [GIT-HANDOFF](../../../GIT-HANDOFF.md).
