# Parrot — agent entry point

Read [README.md](README.md) for the application and build workflow.
Rebuild and validation: [docs/BUILD.md](docs/BUILD.md). Git/evidence boundaries: [docs/GIT-HANDOFF.md](docs/GIT-HANDOFF.md).
For the two-Mac installation, start with [docs/parakeet-ultra/README.md](docs/parakeet-ultra/README.md) and its status/evidence links.

- Verify installed apps and current recording state before replacing software; preserve meeting data and signing identity.
- `project.yml` is the XcodeGen source. Keep its SDK versions aligned with `Package.swift` and resolved dependencies.
- Primary M5 Pro runs the validated 2026-10-09 improvement, including Best Transcript batching and local hybrid refinement. Start with [release state](docs/performance/improvement-2026-10-09/STATE.md). The second Mac was not changed by this release; its dated Ultra installation remains historical evidence.
- Preserve unrelated dirty changes and the recorded pre-task patch. Exact source, signatures, quality gates, private backup and rollback are linked in the release docs.
- Validate changed speech paths with the bounded diagnostics and synthetic fixtures. The network-disabled test bundle proves local operation without changing system network settings.
- Follow parent/global resource rules. Installation helpers and build snapshots are temporary; keep the latest deliverable, rollback app, and small evidence only.
- Do not weaken the Qwen memory guard to make a test pass. Its current limitation on the 16 GB Mac is documented.
