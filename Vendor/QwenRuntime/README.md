# Local Qwen runtime

`llama-server` is the arm64, self-contained runtime embedded in Parrot's app
bundle for on-device meeting-title generation. It links only Apple system
frameworks and is re-signed during every app build with App Sandbox inheritance.

- Upstream: `ggml-org/llama.cpp` tag `b10200`, commit `5f55650a78f92aff4d48d671423e888fac0469ff`
- Runtime version: `1 (5f55650)`
- Minimum macOS: `14.0`
- Build: static libraries, Metal + Accelerate, no cURL/OpenSSL dependency
- SHA-256: `3210cf12144596addf1e39c5b2bc1bb70cd436d619d15d9deb7622660e329896`
- Network behavior: loopback server only; Parrot supplies a random per-launch API key

The build fails closed if the binary is absent or its checksum changes.
