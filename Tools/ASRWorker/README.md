# Native post-call ASR worker

Accepted on the primary M5 Pro, 64 GB, in the [2026-10-09 release](../../docs/performance/improvement-2026-10-09/README.md). Signed inherited-sandbox inference, the exact installed ten-case gate, network-denied clone and worker cancellation passed. Production uses Whisper + Qwen language-switch refinement; direct Qwen and MOSS replacement failed the per-language gate. The second Mac was not updated.

## Reproducible build

Independent ARM64/macOS 14+ tool, compiled with Xcode 27 / Swift 6.4 and the official Metal Toolchain. [project.yml](project.yml) pins mlx-audio-swift at dbe5eaac964e8257785f9d015c81f819a38016a8. [Package.resolved](Package.resolved) fixes the separate dependency graph, including MLX 0.32.3 / MLX LM 3.32.3, transformers 1.3.4 and HuggingFace 0.13.0. Main app dependencies remain WhisperKit 0.18.0 / FluidAudio 0.17.3.

From the repository root:

```bash
python3 Tools/ASRWorker/build.py
```

The foreground build has a 20-minute deadline, records exact owned PIDs in worker-resources.json, and requires at least 20 GiB free disk. It removes its DerivedData after completion. --keep-scratch is for active incremental work; remove that owned directory after acceptance.

Portable output in the ignored Build/portable directory contains ParrotASRWorker, mlx.metallib, package bundles, manifest.json and ASRWorker.app. Parent project.yml embeds and signs a standard nested app:

```text
Parrot.app/Contents/Helpers/ASRWorker.app/
  Contents/Info.plist
  Contents/MacOS/ParrotASRWorker
  Contents/Resources/mlx.metallib
  Contents/Resources/*.bundle
```

Startup sets GPU.metallib explicitly from the helper resource URL. Build manifests stay outside executable directories. Parent signing uses the preserved identity and [inherited sandbox entitlements](../../Parrot/QwenHelper.entitlements). The final signed helper hash is in the [release seal](../../docs/performance/improvement-2026-10-09/evidence/release-seal.json); an unsigned build hash is a different artifact.

## Protocol and bounds

Run ParrotASRWorker --engine qwen --model-dir /absolute/local/model-folder, or engine moss. Loading uses fromModelDirectory; the worker never downloads models. Logs go to stderr, stdout is newline-delimited JSON. Startup emits event=ready with engine/loadSeconds; failure emits an error and exits.

Each stdin request contains id, audioPath, vocabulary, language and maxTokens. Audio must be 16 kHz mono WAV, greater than zero and at most 120 seconds. Parent windows are bounded to 30 seconds, with no overlap. Vocabulary accepts a string or string array. Language remains accepted for IPC compatibility; inference detects it automatically.

Successful results include text, detected language/languages, relative segments, decodeSeconds, generationTokens, peakMemoryGB and truncated=false. The allocation peak is an MLX metric, not full process RSS. A region reaching its output-token cap becomes an error with truncated=true; truncated text is never saved as complete. Digital silence avoids decoder generation.

Qwen detects adaptive-energy speech regions from unchanged samples and resets language detection per region. 10 ms RMS frames, sustained pauses, edge padding and bounded low-energy splits preserve weak replies and integer sample offsets. This is an energy detector. Its speechRegions timestamps are coarse; there are no word timestamps.

MOSS uses model timestamps when valid. Modest overshoot clips to audio length with timestampsAdjusted=true; invalid or partial timing preserves every generated word with whole-window timing and timestampWarning. Anonymous speaker labels are not stable person identities across windows. Nonempty MOSS vocabulary is rejected because the cancellation-safe throwing API has no prompt argument.

Requests are serial. EOF releases models after the current bounded request; the parent interrupts its exact owned worker on pause/cancel. Parent deadlines: 60 seconds startup, 90 seconds inference, two seconds idle unload. Nonblocking pipe reads accept short replies and support cancellation while stdout remains open; regressions cover the actual child exit. ASR memory guard is 6 GiB, independent of the unchanged 10 GiB Qwen 3.5 9B title guard.

## Verification

Thirteen pure checks in [SignalTests](Tests/SignalTests.swift) cover silence, weak replies, stationary noise, sample offsets, bounded speech, clipping and full-text fallback. Compile Sources/SignalPreprocessing.swift with Tests/SignalTests.swift to an owned Build executable; remove it after the run. No model is needed.

Installed inference and quality evidence lives in the [release report](../../docs/performance/improvement-2026-10-09/README.md), with [model layouts and research](../../docs/performance/improvement-2026-10-09/model-review.md). Portable startup/protocol smoke alone does not prove sandbox inference, timing accuracy or meeting quality. Build/portable is retained for parent builds; integration DerivedData and temporary model copies were removed.
