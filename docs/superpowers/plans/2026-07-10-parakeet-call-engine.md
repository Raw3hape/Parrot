# Parakeet Call Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Parrot's fixed two-second local transcription loop with a fully local, utterance-aware Parakeet V3 engine and on-device Whisper fallback for Polish, Russian, and English calls.

**Architecture:** Keep the existing dual 16 kHz capture and echo cancellation, but feed each source into its own VAD-backed utterance pipeline. FluidAudio Parakeet produces rolling hypotheses and finalized utterances; the existing WhisperKit model handles errors, empty results, and low-confidence finals. All model work stays off the audio callback and drains before meeting persistence.

**Tech Stack:** Swift 5.10/6 interoperability, SwiftUI, AVFoundation, Core ML, FluidAudio 0.15.5, WhisperKit 0.18 resolved by SPM, XcodeGen, existing `--profile-test` executable harness.

## Global Constraints

- Preserve bundle ID `com.uygar.parrot` and the existing SwiftData/audio container.
- Preserve separate `Me` and `Them` streams and the current echo cancellation path.
- Use no cloud transcription, post-pass, or copilot APIs in this personal build.
- Use Parakeet TDT 0.6B V3 as the default engine and `large-v3-v20240930_turbo` as local fallback.
- Support Polish, Russian, and English in multilingual auto mode.
- Never run model inference on the realtime audio callback.
- Never log transcript text or raw audio.
- Implement behavior through failing tests before production code.

---

### Task 1: Establish the baseline and add FluidAudio

**Files:**
- Modify: `Package.swift`
- Modify: `project.yml`
- Regenerate: `Parrot.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: an importable `FluidAudio` module pinned to `0.15.5` in both build entrypoints.

- [ ] **Step 1: Run the existing baseline harness**

Run:

```bash
xcodebuild -project Parrot.xcodeproj -scheme Parrot -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
.build/xcode/Build/Products/Debug/Parrot.app/Contents/MacOS/Parrot --profile-test
```

Expected: build exits `0`; harness ends with `ALL PASS`.

- [ ] **Step 2: Add the exact package dependency**

Add to `Package.swift`:

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
```

and to the executable target dependencies:

```swift
.product(name: "FluidAudio", package: "FluidAudio"),
```

Add the matching XcodeGen package:

```yaml
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio.git
    exactVersion: "0.15.5"
```

and target dependency:

```yaml
      - package: FluidAudio
        product: FluidAudio
```

- [ ] **Step 3: Regenerate and verify dependency resolution**

Run:

```bash
xcodegen generate
xcodebuild -project Parrot.xcodeproj -scheme Parrot -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **` and `FluidAudio` appears in resolved packages.

- [ ] **Step 4: Commit**

```bash
git add Package.swift project.yml Parrot.xcodeproj/project.pbxproj Parrot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build: add FluidAudio for local call transcription"
```

---

### Task 2: Build the pure utterance state machine with TDD

**Files:**
- Test: `Parrot/ProfileTest.swift`
- Create: `Parrot/Services/UtteranceSegmentation.swift`

**Interfaces:**
- Consumes: absolute 16 kHz sample chunks plus VAD boundary events.
- Produces: `UtteranceEmission.preview(UtteranceAudio)` and `.final(UtteranceAudio)`.

Required public-in-module contracts:

```swift
struct CallSegmentationConfig: Sendable, Equatable {
    let sampleRate: Int
    let minSpeechSamples: Int
    let previewIntervalSamples: Int
    let maximumUtteranceSamples: Int
    let overlapSamples: Int
    let retainedPrerollSamples: Int
    static let callDefault: Self
}

struct UtteranceAudio: Sendable, Equatable {
    let samples: [Float]
    let startSample: Int
    let endSample: Int
    let generation: Int
    let forcedSplit: Bool
}

enum SpeechBoundary: Sendable, Equatable {
    case started(atSample: Int)
    case ended(atSample: Int)
}

enum UtteranceEmission: Sendable, Equatable {
    case preview(UtteranceAudio)
    case final(UtteranceAudio)
}

struct UtteranceAssembler: Sendable {
    init(config: CallSegmentationConfig = .callDefault)
    mutating func append(_ samples: [Float], absoluteStartSample: Int) -> [UtteranceEmission]
    mutating func apply(_ boundary: SpeechBoundary) -> [UtteranceEmission]
    mutating func flush(atSample: Int) -> [UtteranceEmission]
    var retainedSampleCount: Int { get }
}
```

- [ ] **Step 1: Write failing segmentation checks**

Add `testUtteranceSegmentation()` to `ProfileTest.run()` with checks that:

```swift
var short = UtteranceAssembler(config: .callDefault)
_ = short.append(Array(repeating: 0.2, count: 2_400), absoluteStartSample: 0)
_ = short.apply(.started(atSample: 0))
let shortFinal = short.apply(.ended(atSample: 2_400))
check("utterance preserves 150ms reply", shortFinal.finalAudio?.samples.count == 2_400)

var long = UtteranceAssembler(config: .callDefault)
_ = long.apply(.started(atSample: 0))
var longEmissions: [UtteranceEmission] = []
for offset in stride(from: 0, to: 240_000, by: 4_000) {
    longEmissions += long.append(Array(repeating: 0.2, count: 4_000), absoluteStartSample: offset)
}
check("utterance emits rolling previews", longEmissions.previewCount >= 8)
check("utterance caps long speech", longEmissions.containsForcedFinal)
check("utterance active buffer stays bounded", long.retainedSampleCount <= 240_000)

var tail = UtteranceAssembler(config: .callDefault)
_ = tail.apply(.started(atSample: 0))
_ = tail.append(Array(repeating: 0.2, count: 8_000), absoluteStartSample: 0)
check("utterance flushes final tail", tail.flush(atSample: 8_000).finalAudio?.endSample == 8_000)
```

Add small test-only collection helpers in `ProfileTest.swift` rather than production code.

- [ ] **Step 2: Run RED verification**

Run the Debug build command from Task 1.

Expected: compilation fails because `UtteranceAssembler` and related contracts do not exist.

- [ ] **Step 3: Implement the minimal state machine**

Implement the contracts above with:

```swift
static let callDefault = CallSegmentationConfig(
    sampleRate: 16_000,
    minSpeechSamples: 2_400,
    previewIntervalSamples: 20_000,
    maximumUtteranceSamples: 224_000,
    overlapSamples: 16_000,
    retainedPrerollSamples: 2_400
)
```

The assembler must keep absolute offsets, retain pre-roll while idle, emit
replaceable previews only while active, finalize only utterances at least
`minSpeechSamples`, retain exactly `overlapSamples` after a forced final, and
invalidate earlier previews by incrementing `generation` on every final/reset.

- [ ] **Step 4: Run GREEN verification**

Build and run `--profile-test`.

Expected: all new segmentation checks and the existing harness pass.

- [ ] **Step 5: Commit**

```bash
git add Parrot/ProfileTest.swift Parrot/Services/UtteranceSegmentation.swift
git commit -m "feat: segment live calls into bounded utterances"
```

---

### Task 3: Add model adapters and fallback routing with TDD

**Files:**
- Test: `Parrot/ProfileTest.swift`
- Create: `Parrot/Services/LocalRecognitionRouter.swift`
- Create: `Parrot/Services/ParakeetModelService.swift`
- Create: `Parrot/Services/WhisperModelService.swift`

**Interfaces:**
- Consumes: finalized or preview `UtteranceAudio`.
- Produces: normalized `LocalRecognitionResult` with engine, confidence, and timings.

Contracts:

```swift
enum LocalSpeechEngine: String, Sendable { case parakeet, whisper }

struct LocalRecognitionResult: Sendable, Equatable {
    let text: String
    let confidence: Float?
    let engine: LocalSpeechEngine
}

protocol LocalSpeechRecognizing: Sendable {
    func transcribe(samples: [Float], language: String?) async throws -> LocalRecognitionResult
}

struct RecognitionFallbackPolicy: Sendable {
    let confidenceThreshold: Float
    func needsFallback(_ result: LocalRecognitionResult) -> Bool
}

actor LocalRecognitionRouter {
    init(primary: any LocalSpeechRecognizing,
         fallback: any LocalSpeechRecognizing,
         policy: RecognitionFallbackPolicy = .init(confidenceThreshold: 0.45))
    func transcribePreview(_ audio: UtteranceAudio, language: String?) async throws -> LocalRecognitionResult
    func transcribeFinal(_ audio: UtteranceAudio, language: String?) async throws -> LocalRecognitionResult
}
```

- [ ] **Step 1: Write failing fallback policy checks**

Add checks for high confidence staying on Parakeet, low confidence falling back,
empty text falling back, primary error falling back, and fallback error retaining
a non-empty primary result.

- [ ] **Step 2: Run RED verification**

Expected: compile failure for missing recognition types.

- [ ] **Step 3: Implement policy and router**

`transcribePreview` calls only the primary recognizer. `transcribeFinal` calls
fallback when primary throws, is empty after trimming, or confidence is `<0.45`.
If fallback throws and the primary text is non-empty, return the primary result.
Neither router nor adapters log recognized text.

- [ ] **Step 4: Implement Parakeet adapter**

Use:

```swift
let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)
let manager = AsrManager(config: .default, models: models)
var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
let result = try await manager.transcribe(samples, decoderState: &decoderState)
```

Pad inputs shorter than 4,800 samples to 4,800. Map `ASRResult.text` and
`ASRResult.confidence` without adding a language lock.

- [ ] **Step 5: Extract the existing Whisper logic into an adapter**

Load `large-v3-v20240930_turbo`, build the existing anti-hallucination
`DecodingOptions`, reuse custom vocabulary prompting, and return cleaned text.
Keep `TranscriptionEngine.cleaned` and hallucination behavior source-compatible.

- [ ] **Step 6: Run GREEN verification**

Build and run `--profile-test`.

Expected: all fallback checks pass.

- [ ] **Step 7: Commit**

```bash
git add Parrot/ProfileTest.swift Parrot/Services/LocalRecognitionRouter.swift Parrot/Services/ParakeetModelService.swift Parrot/Services/WhisperModelService.swift
git commit -m "feat: add Parakeet recognition with local Whisper fallback"
```

---

### Task 4: Integrate Silero VAD and dual-stream orchestration with TDD

**Files:**
- Test: `Parrot/ProfileTest.swift`
- Create: `Parrot/Services/CallStreamProcessor.swift`
- Modify: `Parrot/Services/TranscriptionEngine.swift`

**Interfaces:**
- Consumes: arbitrary capture buffers from `appendAudio(_:source:)`.
- Produces: replaceable `currentText` previews and exactly-once final `onSegment` callbacks.

Contracts:

```swift
actor CallStreamProcessor {
    init(source: AudioSource,
         vad: VadManager,
         router: LocalRecognitionRouter,
         config: CallSegmentationConfig = .callDefault)
    func append(_ samples: [Float]) async
    func finish() async
    func cancelPreviews() async
    var onPreview: (@Sendable (String, Int) async -> Void)? { get set }
    var onFinal: (@Sendable (LocalRecognitionResult, Int, Int) async -> Void)? { get set }
}
```

- [ ] **Step 1: Write failing stream-isolation and stale-preview checks**

Use fake recognizers and synthetic boundaries to verify that `Me` and `Them`
maintain independent absolute timestamps, a final generation rejects an older
preview, and `finish()` emits the last partial utterance once.

- [ ] **Step 2: Run RED verification**

Expected: compile failure for missing stream processor/orchestration behavior.

- [ ] **Step 3: Implement `CallStreamProcessor`**

Accumulate exactly 4,096 samples per Silero call. Maintain one
`VadStreamState` per processor and call:

```swift
let output = try await vad.processStreamingChunk(
    frame,
    state: vadState,
    config: VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.65,
        maxSpeechDuration: 14,
        speechPadding: 0.15
    )
)
```

Feed emitted absolute boundaries into `UtteranceAssembler`. Run previews in
cancellable generation-scoped tasks. Queue finals and await them during
`finish()`. If Silero throws, use the same assembler with a mean-absolute-energy
decision (`>0.002`) and the same silence duration.

- [ ] **Step 4: Replace the fixed two-second loop**

`TranscriptionEngine` owns one Parakeet service, one Whisper service, one
router, one VAD manager, and two `CallStreamProcessor` actors. `appendAudio`
copies samples and yields to a per-source ordered queue; it never awaits model
work. Final callbacks preserve sample-derived timestamps and existing speaker
labels. Remove Groq/Deepgram selection from the active path.

- [ ] **Step 5: Preserve stop ordering**

`stopTranscribing()` invalidates previews, flushes both stream processors,
awaits all final recognition, then clears UI state and buffers.

- [ ] **Step 6: Run GREEN verification and a 10-minute synthetic feed**

Run the harness and a logic stress flag that feeds alternating speech/silence
frames to both streams without loading models.

Expected: all checks pass, no duplicate finals, retained samples stay bounded.

- [ ] **Step 7: Commit**

```bash
git add Parrot/ProfileTest.swift Parrot/Services/CallStreamProcessor.swift Parrot/Services/TranscriptionEngine.swift
git commit -m "feat: transcribe dual call streams by natural utterance"
```

---

### Task 5: Preserve the local-only product and expose model readiness

**Files:**
- Modify: `Parrot/Services/RecordingManager.swift`
- Modify: `Parrot/ParrotApp.swift`
- Modify: `Parrot/Views/SettingsView.swift`
- Modify: `Parrot/Views/OnboardingView.swift`
- Modify: `Parrot/Models/AIUsage.swift`
- Test: `Parrot/ProfileTest.swift`

**Interfaces:**
- Produces: a Parakeet-first local engine UI with visible download/load/fallback states.

- [ ] **Step 1: Write failing local-policy checks**

Add a pure `PersonalBuildPolicy.apply(to:)` contract and tests that it sets:

```swift
transcriptionBackend = "local"
polishAfterCall = false
copilotEnabled = false
localSpeechEngine = "parakeet"
whisperModel = "large-v3-v20240930_turbo"
transcriptionLanguage = "auto"
```

- [ ] **Step 2: Run RED verification**

Expected: compile failure for missing policy.

- [ ] **Step 3: Implement and apply local policy at app startup**

Apply before `ParrotApp.main()` and keep it idempotent. Do not delete keys or
stored meetings.

- [ ] **Step 4: Replace cloud-facing settings**

Show two local choices only:

```swift
Text("Parakeet V3 — Recommended for PL / RU / EN").tag("parakeet")
Text("Whisper Large V3 Turbo — Compatibility").tag("whisper")
```

Show Parakeet/VAD/Whisper readiness, one download/reload action, `Auto`,
`Polish`, `Russian`, and `English` language rows, and a privacy caption that
states the one-time model download is the only network use. Hide Groq,
Deepgram, post-call polish, and Copilot controls in this personal build.

- [ ] **Step 5: Update lifecycle and usage labels**

`RecordingManager.prepare` loads local services; `writeAIUsage` records a free
on-device line without reading cloud settings; `polishTranscript` remains a
no-op because policy disables it.

- [ ] **Step 6: Run GREEN verification and render Settings**

Run the harness and app snapshot/smoke build.

Expected: local-policy checks pass and no cloud engine is visible/selectable.

- [ ] **Step 7: Commit**

```bash
git add Parrot/ProfileTest.swift Parrot/Services/RecordingManager.swift Parrot/ParrotApp.swift Parrot/Views/SettingsView.swift Parrot/Views/OnboardingView.swift Parrot/Models/AIUsage.swift
git commit -m "feat: make Parakeet the private local call engine"
```

---

### Task 6: Add and run local integration verification

**Files:**
- Create: `Parrot/ParakeetIntegrationTest.swift`
- Modify: `Parrot/ParrotApp.swift`

**Interfaces:**
- Produces: `--parakeet-test <audio> [expected-fragment]` and
  `--dual-stream-test <audio-a> <audio-b>` commands that never print transcript
  content unless an explicit expected fragment is supplied.

- [ ] **Step 1: Write the CLI dispatch before the implementation**

Add argument parsing calls referencing missing `ParakeetIntegrationTest`.

- [ ] **Step 2: Run RED verification**

Expected: compile failure for the missing integration harness.

- [ ] **Step 3: Implement integration harness**

Load Parakeet/VAD, transcribe a file, and print only engine, duration,
processing time, confidence, and whether the optional expected fragment
matched. The dual-stream mode runs two ordered feeds and reports segment counts
plus maximum recognition lag without transcript text.

- [ ] **Step 4: Create public/synthetic language fixtures**

Use installed macOS voices where available or public FLEURS samples. Produce
16 kHz mono fixtures for Polish, Russian, and English outside the repository.

- [ ] **Step 5: Download/cache models and verify all languages**

Run the integration command for all three fixtures and the dual-stream test.

Expected: non-empty text, expected fragment match where deterministic, no
errors, no backlog, and local caches populated.

- [ ] **Step 6: Replay existing Parrot audio locally**

Run against existing `.caf` files while suppressing transcript text. Record
only duration, segment count, confidence distribution, errors, and latency.

- [ ] **Step 7: Verify offline operation**

Disable network for the test process or run with network access blocked after
caches exist; repeat one fixture.

Expected: successful transcription from local caches.

- [ ] **Step 8: Commit**

```bash
git add Parrot/ParakeetIntegrationTest.swift Parrot/ParrotApp.swift
git commit -m "test: add local multilingual Parakeet verification"
```

---

### Task 7: Full verification, Release build, backup, and install

**Files:**
- Verify all changed files.
- Install: `/Applications/Parrot.app`
- Backup: `/Users/nikita/Applications/Parrot Backups/<timestamp>/Parrot.app`

**Interfaces:**
- Produces: installed app using the same bundle ID and data container.

- [ ] **Step 1: Run the complete test harness fresh**

```bash
xcodebuild -project Parrot.xcodeproj -scheme Parrot -configuration Debug -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
.build/xcode/Build/Products/Debug/Parrot.app/Contents/MacOS/Parrot --profile-test
```

Expected: `ALL PASS`.

- [ ] **Step 2: Run clean Release build**

```bash
xcodebuild -project Parrot.xcodeproj -scheme Parrot -configuration Release -derivedDataPath .build/release CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify bundle identity and local-only strings**

Check `CFBundleIdentifier == com.uygar.parrot`, arm64 architecture, hardened
runtime/ad-hoc signature, required entitlements, Parakeet strings present, and
no cloud choice visible in the Settings source/snapshot.

- [ ] **Step 4: Back up current app and install atomically**

Quit Parrot, copy the existing app to a dated backup directory, copy the Release
bundle into `/Applications/Parrot.app`, and verify code signature plus bundle ID.

- [ ] **Step 5: Launch and smoke test installed app**

Launch from `/Applications`, verify existing meetings are visible, both local
models report ready, permissions remain available, start/stop a short local
recording, and confirm the transcript finalizes after the pause.

- [ ] **Step 6: Inspect logs and stored result**

Verify there are no model exceptions, no backlog, no duplicate `Me`/`Them`
segments, and no network requests after cached model load.

- [ ] **Step 7: Run final repository checks**

```bash
git diff --check
git status --short
git log --oneline --decorate -8
```

Expected: clean worktree and all implementation commits present.

