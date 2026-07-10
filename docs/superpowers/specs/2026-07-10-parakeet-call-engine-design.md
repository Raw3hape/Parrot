# Parakeet Call Engine Design

## Outcome

Parrot will transcribe live calls entirely on the Mac using NVIDIA Parakeet TDT
0.6B V3 as the primary recognizer, Silero VAD for utterance boundaries, and the
already installed Whisper Large V3 Turbo as a local fallback. The target call
languages are Polish, Russian, and English, including short answers, long
monologues, pauses, and language changes between utterances.

The finished app must remain free and usable without an internet connection
after the one-time model download. No audio or transcript text may be sent to a
cloud service.

## Existing Behavior to Preserve

- Keep bundle identifier `com.uygar.parrot` so the existing SwiftData store,
  recordings, microphone permission, and screen-recording permission remain in
  the same app container.
- Keep the separate `Me` microphone stream and `Them` system-audio stream.
- Keep 16 kHz mono Float32 audio capture and the current acoustic echo
  cancellation path.
- Keep the installed Whisper model identifier
  `large-v3-v20240930_turbo` as the fallback model.
- Keep the local-only product behavior: cloud transcription, cloud post-pass,
  and cloud copilot remain disabled in this personal build.
- Existing meetings and audio files must not be migrated, replaced, or deleted.

## Chosen Approach

Use FluidAudio `0.15.5` for its native Swift/Core ML Parakeet V3 and Silero VAD
pipelines. Do not use Python, a sidecar process, CUDA, or a network service.

Each audio source owns an independent utterance state machine. Raw capture
buffers continue arriving without blocking the audio callback. The state
machine detects speech, retains context, schedules live hypotheses, finalizes
an utterance after a natural pause, and forces a safe split during an unusually
long uninterrupted monologue.

Parakeet is a batch recognizer, so live behavior is created by cheaply
re-transcribing the growing current utterance. A live hypothesis is replaceable
UI state; only a finalized result is persisted and passed to downstream call
analysis. Generation identifiers prevent a slow, stale hypothesis from
overwriting a newer final result.

## Audio Segmentation Contract

Use these initial values, independently for `Me` and `Them`:

- sample rate: 16,000 Hz;
- minimum speech duration: 0.15 seconds;
- end-of-utterance silence: 0.65 seconds;
- speech padding: 0.15 seconds before and after detected speech;
- live hypothesis cadence: 1.25 seconds while speech is active;
- maximum finalized utterance: 14 seconds;
- forced-split overlap: 1 second, deduplicated using token/word timings;
- minimum Parakeet input: 0.30 seconds, padded with silence when necessary.

A pause shorter than 0.65 seconds remains part of the same utterance. A short
answer such as `tak`, `nie`, `да`, or `yes` is retained as long as VAD detects at
least 0.15 seconds of speech. Stopping a recording flushes both partial
utterances before the meeting transcript is assembled.

## Recognition and Fallback Policy

Parakeet V3 runs in multilingual auto mode so every finalized utterance may be
Polish, Russian, or English. The app does not hard-lock a whole meeting to one
language.

Whisper Large V3 Turbo handles a finalized utterance when any of these is true:

- Parakeet throws an error;
- Parakeet returns empty text for VAD-confirmed speech;
- Parakeet confidence is below `0.45`.

Fallback remains on-device. Existing Whisper silence and special-token filters
are reused. If Whisper is unavailable, Parakeet's non-empty result is retained;
the app must never discard captured speech solely because the fallback failed.

## Data Flow

1. `AudioCaptureManager` emits 16 kHz mono PCM tagged `Me` or `Them`.
2. `CallAudioPipeline` copies the samples off the realtime callback and routes
   them to the matching `UtteranceSegmenter` actor.
3. Silero VAD emits speech start/end decisions and probability.
4. While speech is active, `LiveHypothesisScheduler` snapshots the growing
   utterance every 1.25 seconds and asks Parakeet for replaceable preview text.
5. Silence or the 14-second cap produces a finalized utterance with absolute
   sample timestamps.
6. `LocalRecognitionRouter` runs Parakeet and applies the Whisper fallback
   policy.
7. The final result becomes one `TranscriptSegment` and is sent once to the
   existing downstream meeting logic.
8. On stop, capture ends first, utterance buffers flush, recognition work
   drains, and only then is the meeting finalized.

## Components and File Boundaries

- `Parrot/Services/UtteranceSegmentation.swift`: pure segmentation state,
  timestamps, padding, forced splits, preview cadence, and flush behavior.
- `Parrot/Services/LocalRecognitionRouter.swift`: Parakeet/Whisper interfaces,
  fallback policy, result normalization, and confidence handling.
- `Parrot/Services/ParakeetModelService.swift`: FluidAudio model download,
  initialization, and transcription adapter.
- `Parrot/Services/TranscriptionEngine.swift`: orchestration only; owns the two
  source pipelines and publishes live/final results.
- `Parrot/Services/RecordingManager.swift`: existing recording lifecycle with a
  deterministic async drain before persistence.
- `Parrot/Views/SettingsView.swift` and `OnboardingView.swift`: show Parakeet as
  the recommended local engine, model state, and a local Whisper compatibility
  option without exposing cloud choices.
- `Parrot/ProfileTest.swift`: deterministic unit-style harness for segmentation,
  stale-preview protection, fallback decisions, two-stream isolation, and stop
  draining.

## Failure Handling

- If Parakeet cannot download or initialize, Parrot remains usable with the
  installed Whisper model and shows a concise local fallback notice.
- If VAD initialization fails, the session uses a conservative energy-based
  utterance detector with the same timing contract instead of returning to
  independent two-second chunks.
- Model inference never runs on the audio callback thread.
- Each source has bounded storage: finalized audio is removed immediately;
  active audio is capped by the 14-second limit plus overlap and padding.
- Cancelling or stopping invalidates outstanding preview generations but drains
  final recognition jobs.
- Errors are logged without transcript text or raw audio content.

## Verification

Automated tests must first fail, then pass, for:

- preservation of a 150–500 ms short reply;
- no split across pauses shorter than 0.65 seconds;
- finalization after 0.65 seconds of silence;
- safe 14-second split with overlap and no duplicate committed words;
- independent `Me` and `Them` state;
- final tail flush on stop;
- stale live preview rejection;
- Parakeet error, empty-result, and confidence fallback paths;
- fallback failure retaining a non-empty Parakeet result;
- bounded active-buffer size.

Integration verification must include:

- a clean Release build with the generated Xcode project;
- loading Parakeet V3 and Silero VAD from their local caches;
- public or synthetic Polish, Russian, and English speech samples;
- simultaneous `Me`/`Them` feed without backlog;
- a local-only replay of existing Parrot recordings, reporting only latency,
  segment counts, and error indicators rather than transcript contents;
- app launch from `/Applications/Parrot.app` with the existing meeting database
  still visible;
- offline smoke test after models are cached.

## Installation and Rollback

Before replacement, copy the current `/Applications/Parrot.app` into a dated
local backup directory. Build with the same bundle identifier and ad-hoc signing
strategy, close the running app, install the new bundle, launch it, and verify
model readiness plus permissions. The app data container is never copied or
modified outside normal application access. Rollback replaces only the app
bundle with the backup.

## Out of Scope

- cloud APIs of any kind;
- translation between languages;
- identifying multiple remote participants by name;
- changing the meeting database schema;
- replacing the existing audio capture or echo cancellation implementation;
- fine-tuning Parakeet or Whisper.
