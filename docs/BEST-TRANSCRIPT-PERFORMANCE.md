# Best Transcript throughput (2026-09-24)

Historical benchmark. The batching work is now integrated in the [accepted primary-Mac release of 2026-10-09](performance/improvement-2026-10-09/README.md), which records fresh serialized controls, background cancellation, hybrid Final and current runtime limits. Percentages below describe the older candidate and its declared fixtures only.

## Why Activity Monitor shows low CPU

WhisperKit 0.18.0 runs its Core ML audio encoder and text decoder primarily on the Neural Engine, with mel computation on GPU by default. The CPU graph alone does not measure that work. Parrot previously passed one 30-second audio window at a time; its `concurrentWorkerCount = 1` could not feed multiple windows to WhisperKit's batch API.

## Change

- `BestTranscriptionCoordinator` groups pending 30-second windows in source order and commits each completed window as a checkpoint. Silent windows and already saved checkpoints remain skipped.
- `WhisperModelService` passes each group to WhisperKit's `transcribeWithResults(audioArrays:)`, which returns results in input order. The background inference gate still allows live work between groups. Recording pause finishes the current group before yielding.
- The group size is bounded by CPU count, physical memory, and a maximum of four. This Mac (M5 Pro, 18 cores, 64 GB) selects four. The integration-test CLI accepts an override for comparison; no product setting or model download was added.

## Local measurements

Both files were generated with macOS `say`, contained one system-audio track, and used the same installed Whisper Large V3 Turbo model. Timings include model setup after the Core ML specialization was warm. They are end-to-end process times from a separate signed test copy; the installed app was not replaced.

| Input | One window | Four windows | Reduction | Result comparison |
| --- | ---: | ---: | ---: | --- |
| Varied English, 303 s | 16.49 s | 13.31 s | 19% | Same text and timestamps, identical SHA-256 |
| Varied Russian, 303 s | 18.78 s | 14.49 s | 23% | 99.9% word match; parallel run added one incorrect word |

Eight windows did not improve the 300-second stress test over four. A deliberately repeated paragraph produced unstable Whisper output across runs, including with one worker, so it was not used to judge text preservation.

The [measurement table](performance/best-transcript-2026-09-24.csv) retains non-content timing and hash evidence. Synthetic audio and transcript exports were removed after verification.

## Verification and limits

All 211 Swift package tests passed, including batching, order, checkpoint resumption, and recording pause during a batch. The real-model CLI checked nonempty output, valid timestamps, no special tokens, and a content hash. The signed Xcode Release candidate processed the varied English file in 13.04 seconds and matched the four-window debug transcript hash exactly. A 95-minute real meeting and a live recording were not benchmarked; do not project the synthetic percentages onto a specific meeting.

The signed candidate is `build/Parrot-optimized-2026-09-24.app`, produced by a full Xcode Release build using local dependency checkouts. `BUILD SUCCEEDED` and `codesign --verify --deep --strict` passed. The installed `/Applications/Parrot.app` was not changed. Entry points: `Parrot/Services/BestTranscriptionCoordinator.swift`, `Parrot/Services/WhisperModelService.swift`, and `Parrot/BestTranscriptionIntegrationTest.swift`.
