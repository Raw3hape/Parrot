# Local Meeting Titles and Transcript-First UI Implementation Plan

> **For Codex:** Execute this plan with test-first changes, task-level review, and fresh end-to-end verification. Preserve the existing dirty worktree and do not stage unrelated files.

**Goal:** Give every eligible meeting a concise, trustworthy 2–4-word local title derived from the entire persisted transcript, then make the meeting detail screen open directly to the transcript beneath the essential metadata and audio player.

**Architecture:** A deterministic on-device `NaturalLanguage` map/reduce engine snapshots every stored segment byte-for-byte, divides only by bounded segment/Unicode ranges, and carries an exact coverage ledger through hierarchical reduction. A single background coordinator processes completed generic-title meetings, yields to recording, never overwrites manual titles, and releases all transient transcript/model state after each job. The generator is behind a protocol so a generative model can be added later without coupling it to recording; Qwen is intentionally excluded from this release because its Swift dependency graph conflicts with the installed WhisperKit and would require a separate transcription migration.

**Tech Stack:** Swift 5.10, SwiftData, Apple NaturalLanguage, CryptoKit, SwiftUI, XCTest.

---

## Task 1: Exact transcript snapshot, whole-text coverage, and deterministic title engine

**Files:**
- Create: `Parrot/Models/MeetingTitle.swift`
- Create: `Parrot/Services/MeetingTitleSnapshotBuilder.swift`
- Create: `Parrot/Services/LocalMeetingTitleGenerator.swift`
- Test: `Tests/ParrotTests/MeetingTitleSnapshotBuilderTests.swift`
- Test: `Tests/ParrotTests/LocalMeetingTitleGeneratorTests.swift`

1. Write failing tests for stable ordering, byte-for-byte whitespace/Unicode preservation, oversized segment reconstruction, fingerprint changes, and exact-once coverage across a long hierarchy.
2. Run the focused tests and record the expected red result.
3. Implement immutable snapshots, SHA-256 fingerprints, bounded leaves, coverage receipts, multilingual lexical/entity scoring, deterministic tie-breaking, and strict 2–4-word validation.
4. Treat raw transcript text only as data: no instruction inside a transcript can alter generation behavior.
5. Run focused tests to green, including RU/PL/EN, mixed-language, silence, repetitions, `[UNK]`, short calls, and a synthetic 10,000-segment meeting.

## Task 2: Provenance, background lifecycle, and persistence safety

**Files:**
- Modify: `Parrot/Models/Meeting.swift`
- Create: `Parrot/Services/MeetingTitleCoordinator.swift`
- Modify: `Parrot/Services/RecordingManager.swift`
- Modify: `Parrot/ParrotApp.swift`
- Test: `Tests/ParrotTests/MeetingTitleCoordinatorTests.swift`
- Test: `Tests/ParrotTests/RecordingManagerPreparationTests.swift`

1. Write failing tests for default/automatic/manual provenance, legacy placeholder eligibility, custom legacy protection, one-job serialization, manual-edit race, stale transcript regeneration, recording pause/resume, delete, and termination.
2. Add lightweight-migrating Meeting metadata with defaults; infer legacy provenance conservatively.
3. Add a utility-priority single-worker coordinator. It may retain compact fingerprints/results, but never a second persistent raw transcript or an idle model.
4. Enqueue after the final transcript is stable; on startup enqueue eligible old generic titles newest-first; pause and await before loading speech models; resume after recording.
5. Recheck provenance and fingerprint immediately before save. Manual names always win. Failure keeps the date title and never affects audio/transcript.
6. Run focused coordinator and preparation tests to green.

## Task 3: Transcript-first detail and accessible meeting list

**Files:**
- Modify: `Parrot/Views/MeetingDetailView.swift`
- Modify: `Parrot/Views/SidebarView.swift`
- Create: `Parrot/Services/MeetingPresentationPolicy.swift`
- Test: `Tests/ParrotTests/MeetingPresentationPolicyTests.swift`

1. Write failing policy tests for player visibility, processing/empty/failed transcript messages, notes visibility, title/transcript search, and failed status presentation.
2. Remove Report/Insights/Notes tabs from primary detail navigation while preserving all underlying data and existing export behavior.
3. Render editable title, date/duration/speakers/cost, player when audio exists, optional compact Notes disclosure, then transcript as the primary surface.
4. Route rename through the coordinator-aware manager; Return saves, Escape cancels, blank input preserves the previous title.
5. Replace gesture-only sidebar selection and transcript seeking with accessible buttons and honest disabled/empty states.
6. Run focused tests and build the views.

## Task 4: Settings, integration, and regressions

**Files:**
- Modify: `Parrot/Views/SettingsView.swift`
- Modify: `Parrot/Services/RecordingManager.swift`
- Test: `Tests/ParrotTests/MeetingTitleIntegrationTests.swift`

1. Add a simple `Automatic meeting titles` setting, local/privacy explanation, status, and `Generate missing titles` action. Do not add a model download or cloud fallback.
2. Verify disabled states during recording and idempotent queueing/double-click behavior.
3. Run `swift test`, regenerate the Xcode project only if the source graph changed, and run the signed Xcode build/tests.
4. Run `--profile-test` and isolated real-transcript title generation without mutating the live database.
5. Measure launch/idle memory before and after a title job; verify no sustained title-engine allocation and that recording starts normally while background title work is pending.
6. Visually inspect the installed app at default and narrow window sizes, including dark mode, keyboard rename, empty/failed/old meetings, and search.

## Release gates

- Every persisted transcript segment/range participates exactly once; no cleaning, filtering, deduplication, or hidden omission is permitted in the title input.
- Titles remain deterministic, 2–4 meaningful words, and never overwrite manual/custom names.
- No audio or transcript leaves the device; no network call exists in the title path.
- Startup remains lightweight; no title model or transcript copy stays resident while idle.
- Recording always has priority and all pre-existing transcription, Best Whisper export, menu-bar, permissions, and profile tests continue to pass.
- Existing summary/coaching/insights/notes data remains stored and exportable even though transcript is the primary meeting UI.
