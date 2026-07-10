# Parakeet Release Hardening Design

## Outcome

The installed personal build must remain responsive and local-only across
rapid start/stop/reload actions, model failures, delayed audio callbacks,
long calls, app termination, and interrupted post-processing. Existing
meetings, audio files, bundle ID, signing team, and model caches are preserved.

## Confirmed Failure Modes

- Capture callbacks and file writers are not session-scoped, so a delayed old
  callback can cross a stop/start boundary.
- Recognition currently blocks audio draining; a slow final can grow the raw
  queue without limit and make Stop wait forever.
- Model preparation is actor-reentrant and can load the same large model more
  than once.
- Whisper-only recovery uses Whisper as both primary and fallback, causing two
  identical inferences per final.
- Final segment persistence is dispatched through an untracked task, so
  post-processing can begin before the transcript tail is saved.
- A reload during capture startup can produce a recording with no active
  transcription loop.
- VAD-to-energy fallback loses the active boundary, forced-overlap trimming can
  erase a complete repeated phrase, and invalid confidence can bypass fallback.
- A normal `.processing` meeting is marked failed after relaunch instead of
  resuming its local post-processing.

## Chosen Architecture

### Session-scoped capture

Every capture receives a monotonically increasing generation. Hardware
callbacks obtain a strong session snapshot from a lock-protected gate before
doing work. Stop first blocks new production, then waits for in-flight callback
and writer barriers, then closes that generation. A callback from an older
generation can never reach a new transcription sink or file.

The transcription sink is installed and armed before hardware starts. During
stop, hardware production ends before the sink is invalidated, preserving both
the first and last buffers.

### Bounded, non-blocking transcription intake

Raw samples use an amortized O(1) FIFO with a head index instead of copying the
whole backlog for every 4,096-sample chunk. Utterance recognition is queued
separately from VAD ingestion, in final order. Intake therefore continues while
a final is recognized. Stop has a finite drain deadline; on deadline the
session generation is invalidated, queued work is cancelled, saved audio is
kept, and the UI reports local degradation rather than hanging.

### Single-flight model lifecycle

Parakeet and Whisper adapters each own one preparation task. Concurrent callers
await the same task. Reload is disabled while loading, starting, recording, or
stopping. Recording startup revalidates readiness after capture and rolls back
capture plus the temporary meeting if transcription could not start.

Whisper-primary recovery has no fallback recognizer. Confidence normalization
is engine-specific and invalid values always take the conservative path.

### Durable meeting lifecycle

The initial meeting is saved before hardware starts. A later startup failure
deletes that draft and stops any partially-started resources. Final segments
are persisted synchronously on the main actor before the transcription drain
completes. Post-processing tasks are retained and cancellable per meeting;
`.processing` meetings resume after relaunch instead of becoming failed.

Normal Quit while recording is deferred until Stop & Save completes. A force
quit remains recoverable: the meeting is marked interrupted, while any existing
audio and transcript stay visible.

## Recognition Edge Rules

- A Silero failure seeds the energy detector with the current speech-active
  state so it can close, rather than merge, the utterance.
- The emergency energy detector rejects implausible stationary/high-frequency
  noise and retains the existing 150 ms short-speech contract.
- Overlap removal never deletes an entire non-empty finalized hypothesis.
- Empty, non-finite, or low Parakeet confidence can use Whisper; a non-empty
  Whisper result is final and is not sent through Whisper again.
- Preview cancellation is checked before entering expensive inference.
- Both-recognizer failures produce a safe health signal without logging audio or
  transcript content.

## Privacy Boundary

Call audio/text remain on-device. Cloud call features stay disabled by policy
and are additionally rejected inside provider network entry points. Model
download traffic remains allowed. Diagnostic commands print only metrics and
exit non-zero on failure; they never print recognized private text.

## Verification Contract

Tests cover single-flight loading, Whisper-only call count, NaN confidence,
FIFO ordering/compaction, complete-overlap preservation, VAD handoff, noise,
rapid lifecycle state, and local policy. Synthetic integration covers short
speech, silence, PL/RU/EN, 35-second forced splits, two sources, a 31-minute
stream, delayed recognizers, and repeated stop/start. Release verification uses
the installed signed binary, exact cached models, offline recognition, preserved
meeting/audio counts, and app relaunch.

