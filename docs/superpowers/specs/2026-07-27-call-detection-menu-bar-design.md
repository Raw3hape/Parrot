# Call Detection and Persistent Menu Bar Design

## Outcome

Parrot launches at login, stays available from one menu-bar icon, and suggests
recording when macOS reports sustained call-like audio activity. It never
captures audio, loads Whisper, or transcribes in the background merely to
detect a call. Recording begins only after the user presses Start Recording.

## Detection Architecture

`CoreAudioProcessMonitor` listens to the public HAL process object list and to
each process object's input/output activity properties. It emits normalized
snapshots containing process identity and booleans for active input and output.
It does not receive audio samples.

`CallCandidateClassifier` maps browser, native calling-app, and Apple telephony
helper bundle identifiers to stable source families. Browser activity is
correlated with a bounded, in-memory snapshot of visible window titles when
available. Window titles are never persisted or logged. Unknown applications
are ignored unless a visible window has a strong call-provider marker.

`CallSuggestionStateMachine` owns debounce, dismissal, recording suppression,
and end-of-session grace behavior. A candidate must remain call-like for four
seconds before prompting. Dismissal and a completed/aborted Parrot recording
suppress the same normalized source session until it has been inactive for
twelve seconds.

## Browser Boundary

macOS identifies Chrome, Safari, Edge, Arc, Firefox, or Brave as the audio
process; it does not expose the originating tab. A visible title can label a
Google Meet, Teams, Zoom Web, Whereby, Discord, or Slack call. When a background
tab title is unavailable but the browser has sustained input and output,
Parrot shows the truthful generic label “Chrome is using the microphone.”

No browser extension, Accessibility access, Apple Events automation, network
inspection, OCR, or continuous window polling is used in the first version.

## Menu Bar and Launch

The SwiftUI `MenuBarExtra` is replaced by a single `NSStatusItem` and persistent
`NSPopover` that can open programmatically. Manual controls and the call
suggestion use the same icon. The suggestion remains until Start, Dismiss, or
the detected session has actually ended.

`SMAppService.mainApp` manages launch at login. The preference defaults on and
the UI reflects macOS states including enabled and requires-approval. A
completed-onboarding launch starts with the main window hidden; onboarding
remains visible for a first launch. The existing independent Dock visibility
setting is preserved.

## Efficiency and Privacy

The detector is event-driven. It uses a one-shot debounce task and requests
window metadata only after relevant audio activity changes. The normal
background state does not start ScreenCaptureKit and does not load local speech
models. Persistence/profile reconciliation occurs at launch, while model
loading moves to the explicit recording-start path.

No audio, transcript text, full window titles, meeting names, PIDs, or full
paths are written to detector logs. No network fallback exists.

## User and Lifecycle Rules

- Output-only music/video never prompts without a strong call window.
- App launch alone never prompts.
- Input-only activity in a known calling app can prompt only after debounce.
- Browser input plus output prompts even when a tab title is unavailable.
- A visible call window plus either input or output can identify a muted call.
- Parrot's own audio processes are always excluded.
- A double click or repeated detector callback cannot start two recordings.
- Starting, recording, stopping, and Best Whisper work retain their existing
  coordination guarantees.
- Disabling suggestions immediately hides the current suggestion and stops the
  Core Audio listener.
- Sleep, screen lock, and app inactivity do not create delayed duplicate
  prompts; current system state is re-evaluated after wake.
- Audio service restarts rebuild process listeners.

## Verification Contract

Pure tests cover source normalization, browser/native confidence, output-only
rejection, unknown applications, window-title privacy, debounce, transient
activity, dismissal, app switching, recording suppression, idle reset, and
preference defaults. Integration checks cover real Core Audio enumeration,
real output-only playback, login-item status, programmatic popover presentation,
lazy model startup, signed installation, relaunch, and the existing recording
and Best Whisper regression suite.
