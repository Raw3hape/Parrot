# Parakeet Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` and implement each behavior through
> a failing regression before production code.

**Goal:** Close the confirmed lifecycle, concurrency, recovery, privacy, and
recognition edge cases without changing the working local Parakeet fast path.

**Tech stack:** Swift 5.10, Swift Concurrency, SwiftUI, SwiftData,
AVFoundation/ScreenCaptureKit, FluidAudio, WhisperKit, executable profile and
integration harnesses.

## Task 1: Regression harness

- [ ] Add RED checks for FIFO ordering and compaction, non-finite confidence,
  Whisper-primary no-fallback behavior, complete-overlap preservation, VAD
  handoff state, sustained noise, and lifecycle transition guards.
- [ ] Run the profile harness and retain the expected failures as evidence.

## Task 2: Recognition and model lifecycle

- [ ] Make Parakeet and Whisper preparation single-flight.
- [ ] Make fallback optional and engine-aware; normalize Whisper confidence.
- [ ] Check cancellation before expensive preview/final inference.
- [ ] Preserve a whole repeated final when overlap would consume all words.
- [ ] Carry Silero active state into the energy fallback and improve the
  emergency noise gate.
- [ ] Run targeted regressions GREEN.

## Task 3: Capture and transcription session boundaries

- [ ] Add a generation-scoped, lock-protected capture callback/writer gate.
- [ ] Arm the transcription sink before hardware start; stop hardware, barrier
  callbacks/writers, then close the sink.
- [ ] Replace array front-copying with an amortized O(1) sample FIFO.
- [ ] Decouple ordered final recognition from VAD intake and apply a finite stop
  deadline with a visible degraded state.
- [ ] Run delayed-callback, slow-recognizer, long-stream, and rapid lifecycle
  synthetic tests GREEN.

## Task 4: Recording persistence and recovery

- [ ] Save the draft meeting before capture starts and fully roll back any
  subsequent startup failure.
- [ ] Make `startTranscribing` report success and revalidate after capture.
- [ ] Persist final segments synchronously before stop proceeds.
- [ ] Retain/cancel post-process tasks and resume `.processing` meetings after
  relaunch.
- [ ] Defer normal application termination until Stop & Save finishes.
- [ ] Disable reload/onboarding completion at unsafe lifecycle states and show
  actionable local recovery copy.

## Task 5: Privacy and diagnostics

- [ ] Add policy guards at cloud provider entry points used by calls.
- [ ] Remove transcript text from integration command output and return a
  failing exit status on integration failure.
- [ ] Update personal-build documentation and privacy capability copy.

## Task 6: Release verification and installation

- [ ] Fresh Debug and Release builds with strict concurrency diagnostics.
- [ ] Profile harness, synthetic stress suite, Parakeet, exact Whisper fallback,
  dual-stream, and offline cached-model checks.
- [ ] Replace `/Applications/Parrot.app` with the stable Team ID and bundle ID.
- [ ] Verify signature, launch, model readiness, existing meetings/audio, and
  clean git state; retain the existing rollback bundle.

