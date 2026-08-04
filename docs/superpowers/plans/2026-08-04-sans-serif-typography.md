# Sans-Serif Typography Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all Parrot interface typography use Apple system sans-serif without changing content, sizing, or layout.

**Architecture:** Keep typography centralized in `Theme.Typography`, expose the selected title design as a testable token, and apply `.fontDesign(.default)` at every independent SwiftUI scene root. Existing semantic and explicitly sized system fonts continue to inherit native macOS behavior.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, macOS 14+

## Global Constraints

- Do not add an external font dependency or bundled font asset.
- Do not change meeting data, transcripts, summaries, exports, colors, spacing, font sizes, or font weights.
- Menu-bar-only startup and the AppKit fallback window must inherit the same typography.

---

### Task 1: Enforce the shared title design

**Files:**
- Create: `Tests/ParrotTests/TypographyTests.swift`
- Modify: `Parrot/Views/Theme.swift`

**Interfaces:**
- Produces: `Theme.Typography.titleDesign: Font.Design`
- Produces: `Theme.Typography.title(_:) -> Font` using `titleDesign`

- [x] **Step 1: Write the failing regression test**

```swift
import SwiftUI
import XCTest
@testable import Parrot

final class TypographyTests: XCTestCase {
    func testMeetingTitleUsesDefaultSystemDesign() {
        XCTAssertEqual(Theme.Typography.titleDesign, .default)
    }
}
```

- [x] **Step 2: Verify the test fails**

Run: `swift test --filter TypographyTests`
Expected: compilation fails because `titleDesign` does not exist.

- [x] **Step 3: Implement the shared sans-serif token**

```swift
static let titleDesign: Font.Design = .default

static func title(_ size: CGFloat = 27) -> Font {
    .system(size: size, weight: .semibold, design: titleDesign)
}
```

- [x] **Step 4: Verify the focused test passes**

Run: `swift test --filter TypographyTests`
Expected: one test passes with zero failures.

### Task 2: Protect every independent scene root

**Files:**
- Modify: `Parrot/ParrotApp.swift`
- Modify: `Parrot/Services/MenuBarController.swift`
- Modify: `Parrot/SnapshotTool.swift`

**Interfaces:**
- Consumes: SwiftUI `.fontDesign(.default)` environment modifier.
- Produces: consistent default design for main window, settings, menu-bar popover, fallback window, and snapshots.

- [x] **Step 1: Apply `.fontDesign(.default)` to the main and settings scene roots**
- [x] **Step 2: Apply `.fontDesign(.default)` to the AppKit-hosted menu popover and fallback window roots**
- [x] **Step 3: Remove stale serif wording from snapshot documentation**
- [x] **Step 4: Audit active Swift source**

Run: `rg -n '\.serif|NewYork|Georgia|Times|serif title|serif headings' Parrot --glob '*.swift'`
Expected: no matches.

### Task 3: Verify, install, and publish safely

**Files:**
- Modify: `.gitignore`
- Include: all intentional Parrot source, tests, documentation, brand assets, and required local Qwen runtime.
- Exclude: `Local_Transcripts/`, recordings, databases, model caches, build output, and credentials.

**Interfaces:**
- Produces: signed `/Applications/Parrot.app` and a GitHub-backed change history.

- [x] **Step 1: Add `Local_Transcripts/` to the privacy ignore rules**
- [x] **Step 2: Run `swift test` and confirm zero failures**
- [x] **Step 3: build a signed Release app and verify its signature**
- [x] **Step 4: install the Release app without deleting user data**
- [x] **Step 5: inspect dashboard, meeting detail, settings, and menu-bar UI**
- [x] **Step 6: stage only reviewed project files, commit, and push to an accessible GitHub branch**
