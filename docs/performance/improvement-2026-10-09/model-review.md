# Post-call ASR integration review — 2026-10-09

Status updated 2026-10-10: the independent [native worker](../../../Tools/ASRWorker/README.md) is integrated and accepted on the primary M5 Pro. Production keeps Ultra for live capture and uses Whisper + Qwen language-switch refinement for Final. Direct Qwen and MOSS replacements failed the per-language gate. [Exact installed quality/GUI/offline evidence](README.md) governs acceptance; the research and initial pilot decisions below remain historical context.

## Decision and exact runtime

Use an independent, supervised native Swift worker importing `MLXAudioSTT`. Pin [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift/tree/dbe5eaac964e8257785f9d015c81f819a38016a8) to `dbe5eaac964e8257785f9d015c81f819a38016a8`. Its [Package.swift](https://github.com/Blaizzy/mlx-audio-swift/blob/dbe5eaac964e8257785f9d015c81f819a38016a8/Package.swift) declares Swift 6.2/macOS 14, MLX >= 0.30.6, MLX LM >= 3.32.3, transformers >= 1.1.6 and HuggingFace >= 0.8.1. The STT target also imports Core, Codecs and VAD, so this is more than a single model source file.

The inspected upstream resolved graph used MLX 0.32.3, MLX LM 3.32.3, transformers 1.3.4 and HuggingFace 0.12.0. The accepted worker's own [resolved graph](../../../Tools/ASRWorker/Package.resolved) uses HuggingFace 0.13.0 with the other listed versions unchanged. MLX LM 3.32.3 requires MLX 0.32.3; that MLX manifest requires Swift 6.3. The actual host compiler was checked: Apple Swift 6.4. Keep the worker's own graph for reproducibility. The main app remains WhisperKit 0.18.0 / FluidAudio 0.17.3.

[speech-swift](https://github.com/soniqo/speech-swift/tree/cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa) is a real alternative at `cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa`, with Qwen cancellation/long-form tests and MOSS MLX/Core ML inference. Its manifest requires macOS 15 and globally resolves WhisperKit >= 1.0.0, incompatible with the current app's exact 0.18.0 pin if added to the same graph. A separate worker avoids that conflict; adding the full package to Parrot is unnecessary for the first Qwen comparison.

## Models and local folder layouts

These revisions and weight checksums were obtained from the HuggingFace metadata API without fetching weights. Full file metadata: [hf-models.json](model-review-evidence/hf-models.json).

| Model | Exact revision | Weight file / bytes | Native loader |
| --- | --- | --- | --- |
| [Qwen 1.7B 8-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit/tree/a8379a2e2f9e313c9292cdf1af4055ab56d50d55) | `a8379a2e2f9e313c9292cdf1af4055ab56d50d55` | `model.safetensors`, 2,463,307,541 | MLXAudioSTT |
| [Qwen 1.7B 4-bit](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit/tree/78a389c776a5483b2d0d4ea5494e11012e0d6159) | `78a389c776a5483b2d0d4ea5494e11012e0d6159` | `model.safetensors`, 1,603,081,617 | MLXAudioSTT |
| [MOSS original 0.9B](https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize/tree/704aa4a9c304e8520be88901e0d1960158ef5b15) | `704aa4a9c304e8520be88901e0d1960158ef5b15` | `model-00000-of-00001.safetensors`, 1,817,113,576 | MLXAudioSTT |
| [MOSS MLX 5-bit](https://huggingface.co/aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-5bit/tree/88aa6b0de4816abc77f8e24384bce74fb087791a) | `88aa6b0de4816abc77f8e24384bce74fb087791a` | `audio_encoder.safetensors` 624,970,399 + `decoder.safetensors` 409,944,112 | speech-swift; different format |

Qwen flat, writable folder: `config.json`, `model.safetensors`, `vocab.json`, `merges.txt`, `tokenizer_config.json`. `fromModelDirectory` creates `tokenizer.json` from the three tokenizer files if missing, then loads it locally. Keep optional `preprocessor_config.json`, `generation_config.json` and the provenance manifest alongside the required files. No `.py` or external Python installation is involved.

MOSS flat folder for MLXAudioSTT: `config.json`, `model-00000-of-00001.safetensors`, `tokenizer.json`, `tokenizer_config.json`, `processor_config.json`, and the supplied tokenizer auxiliary files (`special_tokens_map.json`, `added_tokens.json`, `vocab.json`, `merges.txt`). Swift loads processor metadata and all `.safetensors` in that folder directly. No downloaded remote Python code is executed.

The speech-swift MOSS 5-bit export has separate audio/decoder keys and `export_config.json` / `source_config.json`. It is **not** a drop-in weight folder for MLXAudioSTT. The unresolvable unauthenticated IDs `mlx-community/MOSS-Transcribe-Diarize` and `mlx-community/MOSS-Transcribe-Diarize-4bit` must not be invented as supported downloads.

Weight SHA256: Qwen 8-bit `bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c`; Qwen 4-bit `9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45`; original MOSS `9a0ceb4ab7330357db3ff583dba8d83625d5b733b00e1d55d6970e11b07026c4`. Weight size is not peak process memory.

## API, languages and timestamps

| Requirement | Qwen | MOSS |
| --- | --- | --- |
| Local load | `Qwen3ASRModel.fromModelDirectory(URL)` | `MossTranscribeDiarizeModel.fromModelDirectory(URL)` |
| Inference | Prefer `generateStream(audio:maxTokens:context:language:chunkDuration:...)`; token-loop cancellation checks exist | `generateStream(audio:generationParameters:)` returns model segments; supervised worker can be stopped between requests |
| RU / PL / EN | All three explicitly listed in the [official Qwen card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | Official MOSS card says 50+ languages; RU/EN are named in the multilingual challenge result, PL is not separately proved in the inspected list |
| Vocabulary | `context` is a text prefix/hint; benchmark against an empty hint and retain actual spoken text | Official hotword prompting appended to instruction; preserve canonical timestamp/speaker instruction |
| Timestamps | Qwen ASR emits text; [Qwen ForcedAligner](https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B) supports RU/EN but does not list PL | Model-generated start/end times and anonymous speaker labels |
| Speaker identity | Preserve known mic/system track source independently | `[S01]` etc. are relative within input, never the person's real identity |

Without an aligner, return actual energy-region or whole-window start/end as coarse segments. Never invent per-word times. Apply the window's absolute recording offset in the parent app. MOSS speaker numbers can change across independent windows; do not silently combine `S01` across them as the same person.

## Long-form and memory policy

Host-controlled VAD windows of 15–30 seconds, with a bounded fallback split, are the practical first Qwen route. Pass a fresh output-token budget per window, checkpoint every completed window and reuse one loaded worker. The native Qwen streaming overload shares `maxTokens` across its own internal chunks, so sending an entire meeting with its default 8,192 tokens can truncate the result. Its default internal chunk duration is 20 minutes; this is not the desired latency/memory bound for Parrot.

The first native pilot exposed mixed-language phonetic transcription and overly strict MOSS time validation. The worker revision therefore detects deterministic adaptive-energy pause regions and resets Qwen language detection automatically per region. Input samples/offsets are preserved; no language is forced and no reference text informs boundaries. MOSS modest end overshoot clips to recorded duration; unusable timing falls back explicitly to whole-window bounds while preserving every generated word. Response metadata distinguishes speech-region/model/window timing, clipping and fallback. Thirteen pure preprocessing tests passed, including audible stationary noise; revised model quality must be recorded in a separate pilot, retaining the initial results.

MOSS original advertises 90-minute single-pass inputs. Native long context is real but has a substantial KV cache: speech-swift's analytical estimate for 90 minutes is 7.74 GB FP16 or 4.11 GB INT8 cache, in addition to weights, audio embeddings, output and scratch memory. Use bounded windows until measured long-form memory/cancellation gates pass. Its 90-minute headline is not a 16 GB Mac acceptance result.

On the primary 64 GB Mac, start the quality pilot with Qwen 1.7B 8-bit, one ASR worker and no concurrent summary model. On 16 GB, begin with bounded Qwen 4-bit windows and measure memory/quality before selecting it. Existing Qwen 3.5 9B summary memory guards remain intact. A constrained second Mac need not use the same post-call model as the primary.

The published [MOSS Swift benchmark](https://github.com/soniqo/speech-swift/blob/cbcdfc6be5e723952d29ab6e32af5e22ad8e70fa/docs/benchmarks/moss-mlx.md) confirms Mac inference on an M5 Pro with 48 GB: matched INT5/INT8 runs on 80 English FLEURS clips yielded WER 8.55%/8.27%; a five-file VoxConverse slice yielded DER about 28%, with speaker-count accuracy 40%/20%. These bounded author results do not prove Russian/Polish meeting quality. Qwen's published 1.52% English WER uses LibriSpeech and cannot be compared directly to these FLEURS figures.

## Worker and portable Metal resources

Build the independent tool with Xcode 27/Swift 6.4 and its own pinned SPM graph. MLX's [build instructions](https://github.com/ml-explore/mlx-swift/blob/19601207e9a0de51e03ee6ec0c3c5f3784275075/README.md) say plain command-line SwiftPM cannot compile Metal shaders; use Xcode for the final tool. An XcodeGen tool target can build the pinned package and its shader resources together.

After `xcodebuild -scheme ParrotASRWorker -configuration Release -destination 'platform=macOS' -derivedDataPath <owned-build-dir>`, the helper is in `<owned-build-dir>/Build/Products/Release/ParrotASRWorker`. Locate that build's `mlx-swift_Cmlx.bundle` and its `default.metallib`; copy the worker to the portable output directory and copy/rename the shader to `mlx.metallib` immediately beside it. Keep any additional package resource bundles actually produced by the selected graph.

The [pinned MLX loader](https://github.com/ml-explore/mlx/blob/1f8e74e3f12f31365464a6867c6579f0e9b29d85/mlx/backend/metal/device.cpp) tries a colocated `mlx.metallib` first; `Resources/mlx.metallib` and `mlx-swift_Cmlx.bundle/default.metallib` are other supported locations. Evidence: [metal-locator.json](model-review-evidence/metal-locator.json). A build succeeding without this resource is insufficient.

Production layout: `Parrot.app/Contents/Helpers/ASRWorker.app/Contents/MacOS/ParrotASRWorker`; shaders/package bundles reside in that helper app's `Contents/Resources`. Worker startup explicitly assigns `GPU.metallib` to its resource URL. A flat helper folder containing a JSON build manifest was rejected by parent signing as an unsigned subcomponent, so the generated standard nested app is the installation artifact; build metadata remains outside its executable directory. Sign the helper/app with the preserved identity and inherited-sandbox helper entitlement pattern. Main-app entitlements need not change. Models remain in the app container, passed by absolute local URL. Smoke-test under inherited sandbox and an unrelated working directory to prove independence from DerivedData.

Parent protocol: startup arguments select engine and local model folder; stdout contains only newline-delimited JSON. Startup emits `ready` with load time; each bounded audio request emits result/error with request ID and decode time. Vocabulary is a string (array input is also accepted). Results reaching the output-token cap fail with `truncated:true` instead of being saved as complete. Logs go to stderr. EOF unloads and exits after the current bounded request. Parent cancels/terminates its exact owned worker on pause and starts a fresh worker when resuming from the persisted window checkpoint.

Observed MOSS API limitation: the throwing stream overload has no custom prompt parameter. The synchronous prompt overload uses `fatalError` on an internal generation error. The worker therefore uses the throwing stream overload and explicitly rejects a nonempty MOSS vocabulary hint. The first cross-model quality pilot must use the same empty vocabulary for every engine.

## Quality acceptance plan and recorded outcome

Compare baseline Ultra/Whisper Turbo, Qwen with/without vocabulary hints and MOSS on identical locally retained inputs. Use held-out RU/PL/EN speech plus natural meeting excerpts with names, echo and language switches. Prepare independent exact references; report WER/CER, name accuracy, duplication, omissions, speaker accuracy, cold/warm latency and peak memory separately. Synthetic fixtures prove bounded regressions only.

Promote Qwen only for languages/conditions where local quality improves without unacceptable omissions, new duplicates or unstable latency. Existing audio/transcript versions must survive model errors and cancellation. The accepted run recorded 3/473 synthetic errors for hybrid versus 14/473 for baseline, with RU/PL/EN unchanged; direct Qwen/MOSS failed the no-regression margin. Capture, background priority, ordinary menu/Cmd-Q, playback and network-denied inference passed. Physical status-popover Quit and a natural 90-minute meeting were not verified. Full measurements and limits are in [the release report](README.md); the initial plan does not enlarge that evidence.
