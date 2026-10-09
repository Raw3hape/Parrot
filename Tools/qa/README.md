# Bounded QA for local speech

Entry: [build and validation](../../docs/BUILD.md), [accepted release](../../docs/performance/improvement-2026-10-09/README.md). Tools operate on declared fixtures and owned output directories; private audio/database backups stay outside Git.

| Tool | Purpose |
|---|---|
| run_bounded_job.py | Foreground command with timeout, exact process ownership, log and resource report |
| create_quality_corpus.py | Generate macOS TTS from the predeclared quality-corpus.json; write WAV and manifest |
| download_final_models.py | Download pinned metadata entries; validate weight size/SHA256; report provenance |
| compare_native_models.py | Compare native Qwen/MOSS with the same corpus and empty vocabulary |
| compare_whisper_baseline.py | Run signed Parrot Final diagnostics for whisper/hybrid/qwen/moss and score the references |
| benchmark_final_pipeline.py | Serial workers 1/4/4/1 comparison plus hybrid, with content/timestamp hashes |
| ParrotOwnedDataCheck.swift | Signed container diagnostic for original history hashes and QA artifact checks |

Each Python script provides --help without starting a model. Set an outer timeout with run_bounded_job.py for builds and corpus runs. Record output paths and completion conditions before starting a heavy job. Keep resource reports small, and verify exact owned child exits.

Acceptance uses the same audio/references and model pins for all engines. Report RU, PL, EN and language switches separately; reject per-language regressions above the declared margin. Fix the corpus before evaluation. Preserve failed candidate results and explain the limits of synthetic TTS.

The accepted release retains local Whisper for monolingual windows and uses independently detected Qwen language-switch telemetry for mixed windows. Direct Qwen and MOSS replacements failed the per-language gate. Reference text, fixture IDs and scores must never enter runtime routing.

Raw diagnostics must not expose meeting text. Only --print-fixture-transcript on deliberately synthetic inputs emits transcription content. Installed GUI recording and playback remain separate checks; a unit or CLI pass does not replace them.
