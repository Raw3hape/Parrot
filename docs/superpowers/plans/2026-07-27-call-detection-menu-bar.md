# Call Detection and Persistent Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch Parrot as a low-overhead menu-bar app and offer a persistent, user-confirmed recording action when macOS reports a likely call.

**Architecture:** An event-driven Core Audio monitor produces process activity snapshots. Pure classifier and state-machine components convert those snapshots into a debounced call suggestion, while an AppKit status item presents the suggestion and existing manual controls. `SMAppService.mainApp` manages login launch, and speech model preparation becomes lazy.

**Tech Stack:** Swift 5.10, macOS 14+, CoreAudio HAL, AppKit `NSStatusItem`/`NSPopover`, SwiftUI, SwiftData, ServiceManagement, XCTest.

## Global Constraints

- Never record audio or load Whisper merely to detect a call.
- Never send audio, titles, or detection metadata to a network service.
- Keep one visible menu-bar icon and preserve the existing Dock toggle.
- Preserve existing recording, Best Whisper, meetings, permissions, signing identity, and bundle identifier.
- Window titles may be matched in memory but never persisted or logged.
- Use exact package versions from `project.yml` and `Package.swift`.

---

### Task 1: Pure Call Source Classification

**Files:**
- Create: `Parrot/Services/CallDetectionModels.swift`
- Create: `Parrot/Services/CallCandidateClassifier.swift`
- Test: `Tests/ParrotTests/CallCandidateClassifierTests.swift`

**Interfaces:**
- Produces: `AudioProcessActivity`, `CallWindowInfo`, `CallSource`, `CallCandidate`, and `CallCandidateClassifier.bestCandidate(activities:windows:)`.

- [ ] **Step 1: Write failing classifier tests**

Cover literal expectations for Spotify output-only rejection, Chrome
input/output generic detection, Google Meet title labeling, known native
input-only detection, Apple telephony helper normalization, Parrot exclusion,
and unknown-app rejection.

- [ ] **Step 2: Run the focused test and verify RED**

Run:
`xcodebuild -project Parrot.xcodeproj -scheme Parrot -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO -only-testing:ParrotTests/CallCandidateClassifierTests`

Expected: compile failure because the production types do not exist.

- [ ] **Step 3: Implement the minimal pure classifier**

Use a data-driven source registry with bundle-prefix normalization. Require
input/output evidence according to the approved design and sanitize every
candidate label to a provider/application name rather than retaining a raw
window title.

- [ ] **Step 4: Run focused tests GREEN**

Run the command from Step 2 and require zero failures.

### Task 2: Suggestion Lifecycle State Machine

**Files:**
- Create: `Parrot/Services/CallSuggestionStateMachine.swift`
- Test: `Tests/ParrotTests/CallSuggestionStateMachineTests.swift`

**Interfaces:**
- Consumes: `CallCandidate`.
- Produces: `CallSuggestionStateMachine.update(candidate:now:isRecording:)`,
  `dismiss(now:)`, `accept(now:)`, and observable `suggestion`.

- [ ] **Step 1: Write failing state-machine tests**

Cover four-second debounce, transient activity, same-session dismissal,
twelve-second idle reset, recording suppression, stop-during-active-call,
normalized helper process changes, and switching to a genuinely different call
source.

- [ ] **Step 2: Run focused tests and verify RED**

Expected: compile failure because `CallSuggestionStateMachine` is absent.

- [ ] **Step 3: Implement deterministic state transitions**

Use injected timestamps only; do not hide timers inside the pure state machine.
Keep session identity at normalized source-family granularity.

- [ ] **Step 4: Run focused tests GREEN**

Require every state-machine test to pass.

### Task 3: Core Audio and Window Event Sources

**Files:**
- Create: `Parrot/Services/CoreAudioProcessMonitor.swift`
- Create: `Parrot/Services/CallWindowProvider.swift`
- Create: `Parrot/Services/CallDetectionCoordinator.swift`
- Test: `Tests/ParrotTests/CallDetectionCoordinatorTests.swift`

**Interfaces:**
- Produces: `AudioProcessMonitoring`, `CoreAudioProcessMonitor`,
  `CallWindowProviding`, `CoreGraphicsCallWindowProvider`, and
  `CallDetectionCoordinator`.

- [ ] **Step 1: Write failing coordinator tests**

Use deterministic fake event sources, but assert real coordinator behavior:
one debounce wakeup, no duplicate suggestion, disabling removes listeners and
hides suggestions, and a recording-state update suppresses an open suggestion.

- [ ] **Step 2: Run focused tests and verify RED**

Expected: compile failure for missing coordinator interfaces.

- [ ] **Step 3: Implement event-driven monitoring**

Listen to `kAudioHardwarePropertyProcessObjectList`,
`kAudioProcessPropertyIsRunningInput`, and
`kAudioProcessPropertyIsRunningOutput`. Rebuild per-process listeners when the
list or audio service changes. Read bundle IDs using Core Audio ownership rules,
fall back to `NSRunningApplication`, and never log identity details.

- [ ] **Step 4: Implement bounded window correlation**

Read only on-screen, non-desktop window metadata after relevant audio changes.
Return sanitized `CallWindowInfo` values to the classifier and retain no raw
title after classification.

- [ ] **Step 5: Run coordinator tests and a real enumeration probe GREEN**

Require focused tests to pass and verify that the current Spotify process is
reported as output-only without producing a call candidate.

### Task 4: Programmatic Menu-Bar Popover

**Files:**
- Create: `Parrot/Services/MenuBarController.swift`
- Create: `Parrot/Views/MenuBarPopoverView.swift`
- Modify: `Parrot/Views/MenuBarView.swift`
- Modify: `Parrot/ParrotApp.swift`
- Test: `Tests/ParrotTests/MenuBarPresentationPolicyTests.swift`

**Interfaces:**
- Consumes: `RecordingManager`, `CallDetectionCoordinator`, `ModelContainer`.
- Produces: one `NSStatusItem`, one persistent `NSPopover`, manual controls,
  automatic suggestion presentation, and main-window reopening.

- [ ] **Step 1: Write failing presentation-policy tests**

Cover suggestion precedence over the idle menu, recording precedence over a
suggestion, persistent behavior, and the exact close conditions Start, Dismiss,
disable, and session end.

- [ ] **Step 2: Run focused tests and verify RED**

Expected: missing `MenuBarPresentationPolicy`.

- [ ] **Step 3: Implement the AppKit controller and SwiftUI content**

Replace `MenuBarExtra`, reuse the installed template icon, update the icon for
recording, keep the popover application-defined, and route Start through
`preflightPermissionsAndStart(modelContext:)`.

- [ ] **Step 4: Run focused tests and build GREEN**

Require tests and a Debug build to succeed.

### Task 5: Login Launch and Lightweight Startup

**Files:**
- Create: `Parrot/Services/LaunchAtLoginController.swift`
- Modify: `Parrot/Services/RecordingManager.swift`
- Modify: `Parrot/Views/ContentView.swift`
- Modify: `Parrot/Views/DashboardView.swift`
- Modify: `Parrot/Views/OnboardingView.swift`
- Modify: `Parrot/Views/SettingsView.swift`
- Modify: `Parrot/ParrotApp.swift`
- Test: `Tests/ParrotTests/BackgroundPreferencesTests.swift`

**Interfaces:**
- Produces: `LaunchAtLoginController`, `CallDetectionPreference`,
  lightweight `RecordingManager.prepareApplication(modelContext:)`, and lazy
  model preparation in the shared recording-start entry point.

- [ ] **Step 1: Write failing preference and lazy-start policy tests**

Cover launch/suggestion defaults, explicit persistence, login-service status
mapping, idempotent register/unregister policy, and recording buttons remaining
actionable before the model is loaded.

- [ ] **Step 2: Run focused tests and verify RED**

Expected: missing preference/controller types.

- [ ] **Step 3: Implement login management and settings**

Register `SMAppService.mainApp` once when the default-on preference is active,
surface requires-approval, support unregister, and open Login Items settings
when action is required.

- [ ] **Step 4: Split lightweight application preparation from model loading**

Reconcile persistence/profile state at launch. Load the speech stack inside
the guarded shared Start path and retain double-start, termination, and Best
Whisper priority protections.

- [ ] **Step 5: Hide only the completed-onboarding startup window**

Keep first-run onboarding visible, keep the window object reopenable, and do
not alter the independent Dock preference.

- [ ] **Step 6: Run focused and full tests GREEN**

Require all tests to pass without changing package versions.

### Task 6: End-to-End Hardening and Installation

**Files:**
- Modify only defects proven by a failing regression.
- Update: `docs/superpowers/plans/2026-07-27-call-detection-menu-bar.md`

**Interfaces:**
- Produces: verified signed `/Applications/Parrot.app`.

- [ ] **Step 1: Run full Debug tests and profile harness**

Run Xcode tests plus `swift build` and
`.build/arm64-apple-macosx/debug/Parrot --profile-test`.

- [ ] **Step 2: Build signed Release and verify the bundle**

Generate with xcodegen, build Release, verify `codesign --deep --strict`,
bundle ID, Team ID, entitlements, and exact dependency versions.

- [ ] **Step 3: Install without deleting user data**

Quit the current app normally, replace only `/Applications/Parrot.app`, launch
it, and ensure no temporary Parrot bundle is preferred by Launch Services.

- [ ] **Step 4: Verify live background behavior**

Verify one Parrot process and status item, hidden completed-onboarding launch,
login-item registration state, detector baseline with no prompt, output-only
audio rejection, programmatic synthetic suggestion, Dismiss suppression,
manual Start permission path, Stop, relaunch, and meeting/audio preservation.

- [ ] **Step 5: Run fresh post-install regression verification**

Run the full test suite again, inspect privacy-safe logs for crashes/errors,
and compare the plan line by line against observed evidence before claiming
completion.
