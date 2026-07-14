# Contributing to SwiftAgentKit

Thanks for your interest in contributing! SwiftAgentKit aims to be the
boringly reliable middleware layer of the Swift AI stack, and contributions
of all sizes help.

## Getting started

```bash
git clone https://github.com/JaydenCJ/swift-agent-kit.git
cd swift-agent-kit
swift build
swift test
bash scripts/smoke.sh
```

Requirements: Swift 6.0+ (Xcode 16.2+ on macOS, or the `swift:6.0` toolchain
on Linux). The core library and its tests run on both macOS and Linux —
please make sure your change keeps it that way.

## Ground rules

- **Pure core.** Everything under `Sources/SwiftAgentKit` except
  `Providers/FoundationModelsProvider.swift` must compile on Linux. Apple-only
  frameworks are gated behind `#if canImport(...)`.
- **No new dependencies.** The package intentionally depends only on the
  standard library and Foundation. Provider integrations that need SDKs
  belong in separate packages that depend on SwiftAgentKit.
- **Tests are not optional.** New wire-format code needs tests against
  recorded payloads; new parser code needs edge-case tests (chunk
  boundaries, malformed input). Run `swift test` before opening a PR.
- **Strict concurrency.** The package builds in the Swift 6 language mode.
  Public types should be `Sendable`; avoid `@unchecked Sendable` unless a
  lock or serial execution genuinely guarantees safety (and say so in a
  comment).

## Project layout

| Path | What lives there |
|---|---|
| `Sources/SwiftAgentKit/Core` | `JSONValue`, `JSONSchema`, schema inference, messages, tools |
| `Sources/SwiftAgentKit/Providers` | `ModelProvider` + OpenAI-compatible, Anthropic, Foundation Models |
| `Sources/SwiftAgentKit/Streaming` | SSE parser, tool-call assembler |
| `Sources/SwiftAgentKit/Agent` | the tool-calling loop |
| `Sources/SwiftAgentKit/StructuredOutput` | `generateObject`, lenient JSON extraction |
| `Sources/SwiftAgentKit/MCP` | JSON-RPC, MCP client, stdio transport |
| `Sources/swiftagentkit-demo` | the runnable calendar-agent demo |

## Submitting changes

1. Fork, branch from `main`, and keep PRs focused on one change.
2. `swift test` must pass on your machine.
3. Describe *why* in the PR body — wire-format decisions especially benefit
   from a link to the upstream API docs you followed.
4. New public API needs doc comments. Follow the existing style: what it
   does, a short example when it isn't obvious, and what it throws.

## Reporting bugs

Open an issue with the provider (and server, if local — Ollama, llama.cpp,
LM Studio, …), the request you sent, and the raw response if you can capture
it. `GenerationResponse.raw` exists precisely to make those reports easy.

## Code of conduct

Be kind and constructive. Maintainers may edit or remove content that isn't.
