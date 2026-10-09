---
license: cc-by-4.0
base_model: moondream/parakeet-ultra
language: [en, de, fr, es, it, pt, ru, uk, hr, sl, lv, lt, et, fi, sv, da, nl, pl, cs, sk, hu, ro, bg, el, mt]
pipeline_tag: automatic-speech-recognition
tags: [coreml, parakeet, tdt, speech-recognition, apple-silicon]
library_name: fluidaudio
---

# parakeet-ultra-coreml

Core ML build of [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra), a full-precision
post-training of `nvidia/parakeet-tdt-0.6b-v3`. Same architecture, 25 languages, tokenizer and output conventions as
v3; drop-in for the v3 component contract. Encoder is int8 linear per-channel (595 MB); decoder and joint are
re-exported from the Ultra checkpoint; preprocessor and vocabulary are the v3 ones.

## Usage (FluidAudio ≥ next release)

```swift
let models = try await AsrModels.downloadAndLoad(version: .ultra)
let asr = AsrManager()
try await asr.initialize(models: models)
let result = try await asr.transcribe(audioFileURL)
```

```bash
swift run fluidaudiocli transcribe audio.wav --model-version ultra
```

## Accuracy (FluidAudio, M-series Mac, full corpora, corpus-level WER)

| | v3 (Core ML) | **ultra (this repo)** |
|---|---:|---:|
| LibriSpeech test-clean (2620 files) | 2.27 % | **2.13 %** |
| LibriSpeech test-other (2939 files) | 4.12 % | **3.81 %** |
| FLEURS, 24 languages × 100 samples, mean | 14.81 % | **11.67 %** |

Ultra wins all 24 FLEURS languages. The int8 encoder scores the same WER as an fp16 export (2.13 % / 3.79 %). Speed
is within a few percent of v3 run back to back on the same machine (test-clean 126.7× vs 128.6× on the ANE).

## Files

| File | Notes |
|------|-------|
| `Encoder.mlmodelc` | 595 MB, int8 linear per-channel, iOS 17+/macOS 14+, fixed 15 s window (`mel [1,128,1501]` → `encoder [1,1024,188]`) |
| `Decoder.mlmodelc` | RNNT prediction net, fp16, iOS 17+ |
| `JointDecisionv3.mlmodelc` | single-step joint + top-K 64, fp16, iOS 17+ |
| `Preprocessor.mlmodelc` | v3 mel front-end |
| `parakeet_vocab.json`, `parakeet_v3_vocab.json` | v3 vocabulary |

Conversion recipe: [FluidInference/mobius](https://github.com/FluidInference/mobius) `models/stt/parakeet-ultra/coreml`.
License CC-BY-4.0, as the upstream checkpoint.
