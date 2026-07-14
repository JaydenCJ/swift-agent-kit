#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// A provider backed by Apple's on-device Foundation Models framework
/// (Apple Intelligence). Only compiled on Apple platforms with the
/// FoundationModels SDK; the rest of SwiftAgentKit builds everywhere.
///
/// Text generation and streaming are supported. Dynamic tool calling is on
/// the roadmap: Foundation Models uses its own compile-time `Tool` protocol
/// and `GenerationSchema`, so bridging SwiftAgentKit's runtime tool
/// definitions requires a schema translation layer (tracked in the README
/// roadmap). Until then, pair this provider with prompt-level workflows, or
/// run local models through ``OpenAICompatibleProvider`` for full
/// tool-calling support.
///
/// Feature coverage, stated plainly:
/// - `request.tools` are **ignored** — the model will answer in plain text
///   without calling them (see the roadmap note above).
/// - `request.responseFormat` other than `.text` **throws**
///   ``AgentKitError/unsupported(_:)`` instead of silently returning prose
///   that would later fail JSON decoding. Use ``OpenAICompatibleProvider``
///   or ``AnthropicProvider`` for `generateObject`-style structured output.
/// - `GenerationOptions.temperature` and `.maxTokens` are forwarded to
///   Foundation Models; `.topP`, `.stopSequences`, `.extraBody` and
///   `.extraHeaders` have no Foundation Models equivalent and are ignored.
@available(iOS 26.0, macOS 26.0, *)
public final class FoundationModelsProvider: ModelProvider, @unchecked Sendable {
    /// Provider name used in logs.
    public let name = "foundation-models"

    /// Creates a provider backed by the system default language model.
    public init() {}

    /// Whether the on-device model is available on this machine right now.
    public static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResponse {
        try Self.checkSupported(request)
        let session = makeSession(for: request)
        let prompt = Self.transcriptPrompt(from: request.messages)
        let response = try await session.respond(to: prompt, options: Self.options(from: request))
        return GenerationResponse(
            message: .assistant(response.content),
            finishReason: .stop
        )
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Self.checkSupported(request)
                    let session = self.makeSession(for: request)
                    let prompt = Self.transcriptPrompt(from: request.messages)
                    continuation.yield(.responseStarted(id: nil))
                    var previous = ""
                    for try await snapshot in session.streamResponse(
                        to: prompt,
                        options: Self.options(from: request)
                    ) {
                        let full = snapshot.content
                        if full.hasPrefix(previous) {
                            let delta = String(full.dropFirst(previous.count))
                            if !delta.isEmpty {
                                continuation.yield(.textDelta(delta))
                            }
                        } else {
                            continuation.yield(.textDelta(full))
                        }
                        previous = full
                    }
                    continuation.yield(.finished(reason: .stop, usage: TokenUsage()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Rejects request features Foundation Models cannot honor, instead of
    /// silently producing output that violates the caller's expectations.
    private static func checkSupported(_ request: GenerationRequest) throws {
        switch request.responseFormat {
        case .text:
            break
        case .jsonObject, .jsonSchema:
            throw AgentKitError.unsupported(
                "FoundationModelsProvider does not support constrained response formats yet "
                + "(Foundation Models' @Generable bridging is on the roadmap). "
                + "Use OpenAICompatibleProvider or AnthropicProvider for structured output."
            )
        }
    }

    /// Maps the provider-neutral options onto Foundation Models options.
    /// Only `temperature` and `maxTokens` have equivalents; the rest are
    /// documented as ignored in the type-level doc comment.
    private static func options(from request: GenerationRequest) -> FoundationModels.GenerationOptions {
        FoundationModels.GenerationOptions(
            temperature: request.options.temperature,
            maximumResponseTokens: request.options.maxTokens
        )
    }

    private func makeSession(for request: GenerationRequest) -> LanguageModelSession {
        let systemText = request.messages
            .filter { $0.role == .system }
            .map { $0.text }
            .joined(separator: "\n\n")
        if systemText.isEmpty {
            return LanguageModelSession(model: SystemLanguageModel.default)
        }
        return LanguageModelSession(model: SystemLanguageModel.default, instructions: systemText)
    }

    /// Flattens the non-system conversation into a single prompt. Foundation
    /// Models sessions are stateful, but `ModelProvider` is stateless by
    /// design, so history is replayed per call.
    static func transcriptPrompt(from messages: [ChatMessage]) -> String {
        let turns = messages.filter { $0.role == .user || $0.role == .assistant }
        if turns.count == 1, let only = turns.first, only.role == .user {
            return only.text
        }
        return turns.map { message in
            switch message.role {
            case .user: return "User: \(message.text)"
            case .assistant: return "Assistant: \(message.text)"
            default: return message.text
            }
        }.joined(separator: "\n\n")
    }
}
#endif
