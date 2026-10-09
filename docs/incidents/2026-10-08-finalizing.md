# Finalizing hang — 2026-10-08

## Outcome

Follow-up, 2026-10-09: the primary Mac now has the [accepted capture/termination fix and Final pipeline](../performance/improvement-2026-10-09/README.md). Stop, ordinary app-menu Quit and immediate Cmd-Q passed installed GUI checks. Status-popover termination ordering passed a regression test; physical popover Quit was not verified. The recovery described below remains preserved; the old zero-duration row was not silently rewritten.

The hung installed Parrot was stopped after preserving its audio and SwiftData store. No replacement app was installed. The existing unfinished Best Transcript changes were not changed.

Private recovery entry point: [README](../../recordings/recovery/2026-10-08-finalizing/README.md). That entire directory is ignored by Git. It contains the readable recording up to the displayed Stop time (4,248 seconds / 1:10:48), its 368 persisted transcript segments, the complete two CAF snapshots, and the pre-stop database with its WAL. Meeting content stays in that private directory.

## Verified observations

- Running executable: `/Applications/Parrot.app/Contents/MacOS/Parrot`, SHA256 `7a5be67795849ef393827dc347f6e0631de042e7f4d2a58304d2221e0f1bcec3`. This matches [the Ultra installation record](../parakeet-ultra/status.json).
- The UI displayed `Finalizing recording 1:10:48`; the durable row still had `recording` status and zero duration. System and microphone CAF files continued growing after Stop. Their snapshot durations were approximately 8,287.4 seconds. The additional audio and transcript are retained in the private raw snapshot, separately from the export ending at Stop.
- A three-second process sample showed every sampled stop-task frame blocked in `AudioCaptureManager.stopCapture() + 680` → Observation mutation → `SwiftUICore.UpdateGroup.begin()` → `_MovableLockLock` → `__psynch_mutexwait`, on the cooperative background executor. It had not reached ScreenCaptureKit shutdown or the transcription drain timeout.
- The main thread was inside synchronous `NSApplication.terminate` / `_shouldTerminate`, entered from the Quit button in `MenuBarView.body`. The window still responded to navigation.
- The copied SQLite database passed `quick_check`. Both copied CAF files opened with Apple's audio reader. The recovered AAC file passed a complete decode, with its media duration checked against 4,248 seconds. Exact results are in `evidence/recovery-validation.json` under the private recovery directory.
- Original PID 2227 was suspended to freeze the snapshot, then exited after SIGTERM followed by SIGCONT. Exit was verified. SIGKILL was not needed.

## Cause and follow-up boundary

Confirmed failure location: audio-stop lifecycle state was being published through Observation from a background executor and blocked on the SwiftUI update lock, before hardware shutdown. The source `AudioCaptureManager` is `@Observable` and `@unchecked Sendable`; its async `stopCapture` is not isolated to `MainActor`. `RecordingManager` is main-actor isolated, but awaiting this method moves its execution off that actor. The transcript's 30-second drain deadline cannot help because execution never reaches it.

The sample strongly indicates that synchronous Quit from inside the SwiftUI button action held the UI update scope while AppKit waited for `.terminateLater` to finish. Mutex ownership was not independently inspected, so this trigger is an inference from the two sampled stacks, rather than an independently reproduced scenario.

Before installing a permanent fix, isolate observed start/stop lifecycle updates to the main actor and defer the Quit request out of the SwiftUI button action. Validate Stop alone, immediate Quit during Stop, and Quit through the menu-bar popover using bounded synthetic capture. Preserve the Ultra source snapshot/package pins and keep unfinished Best Transcript work out of an installation candidate. This incident recovery did not install that fix.

## Resource handback

The original Parrot process is closed. Bounded log collection, sampling, audio export, and decode validation ended; their process exits were checked. The recovery directory is the deliverable, not temporary build output. No browser, renderer, model download, or build was started. Existing Computer Use service processes predated this task and were left alone. The task's separate Finder window was closed after copying. Other apps and recordings were not changed.
