# Parrot Sans-Serif Typography

## Goal

Use one calm, native macOS sans-serif typography system throughout Parrot. Meeting titles, summaries, reports, transcripts, settings, onboarding, recording surfaces, and the menu-bar popover must not introduce serif interface text.

## Decision

Keep Apple system typography and the existing size/weight hierarchy. Change the shared editorial title token from `.serif` to `.default`, then apply the default font design at the application scene roots as a safety net for semantic SwiftUI fonts.

This avoids a bundled font, preserves Dynamic Type and localization behavior, and makes future views inherit the same typography without manual font replacement.

## Scope

- Change `Theme.Typography.title` to use the default system font design.
- Apply the default font design to the main window, settings scene, and menu-bar popover root.
- Update development snapshot descriptions so they no longer document a serif title.
- Add a regression test for the shared title design.
- Do not change font sizes, weights, colors, spacing, transcript content, meeting data, or exported text.

## Verification

- Source audit contains no active `.serif`, custom serif font, or stale serif design description.
- Typography regression test passes.
- Full Swift test suite and signed Release build pass.
- Installed app is inspected on dashboard, meeting detail, settings, and menu-bar surfaces.

