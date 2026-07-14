# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-08

### Added

- **Provider abstraction** — the `ModelProvider` protocol: one request/response
  shape (`GenerationRequest` / `GenerationResponse` / `StreamEvent`) that
  drives on-device and cloud models interchangeably.
- **OpenAI-compatible provider** with presets for Ollama, llama.cpp
  (`llama-server`), LM Studio, vLLM and OpenAI — covering most local-model
  servers with one implementation (any other compatible server works via the
  generic initializer). Full request encoding (tools, `tool_choice`,
  `response_format: json_schema`, multimodal content) and response/stream
  decoding.
- **Anthropic provider** for the Messages API: system-prompt extraction,
  `tool_use`/`tool_result` block mapping (tool results merged into a single
  user turn), `output_config` structured output, and native SSE event
  stream decoding (`message_start` → `content_block_delta` →
  `input_json_delta` → `message_stop`).
- **Foundation Models provider** (gated behind `#if canImport(FoundationModels)`)
  for Apple Intelligence on-device text generation and streaming.
  `temperature`/`maxTokens` map to Foundation Models options; constrained
  response formats throw a clear `unsupported` error until `@Generable`
  bridging lands (tools are ignored, as documented).
- **Agent loop** — `Agent` runs the prompt → tool-call → tool-result loop
  with parallel tool execution, per-step records, error feedback to the
  model, usage accounting and a `maxSteps` budget.
- **Tool calling** — `Tool.typed` builds a tool from a plain Swift closure,
  decoding the model's JSON arguments into your `Codable` input type.
- **Schema inference** — `JSONSchema.infer(from:)` derives a JSON Schema from
  any `Decodable` type via a probing decoder: no macros, no hand-written
  schemas. Supports nested structs, arrays, optionals (→ non-required),
  `CaseIterable` string enums (→ `enum` schemas), `Date`/`URL`/`UUID`/`Data`.
- **Structured output** — `generateObject(_:provider:prompt:)` sends a
  JSON-Schema response format and decodes the reply into your type, with
  lenient extraction for fenced/prose-wrapped JSON. Strict mode is requested
  by default but automatically downgraded for schemas strict-mode providers
  reject (open/dictionary-shaped objects); override with `strict:`.
- **Streaming** — incremental WHATWG-conformant SSE parser (chunk-boundary
  safe, including boundaries inside multi-byte UTF-8 characters) and a
  tool-call assembler for fragmented streaming arguments.
- **MCP client** — JSON-RPC 2.0 over pluggable transports (stdio subprocess
  on macOS/Linux, in-memory for tests): `initialize` handshake, `tools/list`,
  `tools/call`, out-of-order response matching, automatic `ping` replies,
  and one-line bridging of MCP tools into the agent loop via
  `MCPClient.tools()`.
- **`JSONValue`** — Sendable JSON model with literals, subscripts, Codable
  bridging and deterministic (sorted-key) canonical serialization.
- **Demo executable** — `swiftagentkit-demo`, a calendar agent that runs
  fully offline (`--offline`) or against any OpenAI-compatible endpoint.
- Test suite: 127 XCTest cases across 13 files covering the pure core,
  written to run on both macOS and Linux (`swift test`), including a test
  that covers the README quickstart example verbatim.

[0.1.0]: https://github.com/JaydenCJ/swift-agent-kit/releases/tag/0.1.0
