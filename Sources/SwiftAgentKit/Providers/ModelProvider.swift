import Foundation

/// The one protocol every backend implements.
///
/// A `ModelProvider` turns a provider-neutral ``GenerationRequest`` into a
/// completed ``GenerationResponse`` (or a stream of ``StreamEvent``s). The
/// rest of SwiftAgentKit — the agent loop, structured output, MCP tool
/// bridging — is written against this protocol only, so the same app code
/// drives on-device models and cloud APIs interchangeably.
public protocol ModelProvider: Sendable {
    /// Human-readable provider name, for logging and diagnostics.
    var name: String { get }

    /// Generates a complete response.
    func generate(_ request: GenerationRequest) async throws -> GenerationResponse

    /// Streams a response incrementally.
    ///
    /// Implementations must emit `.finished` as the terminal event before
    /// the stream ends normally.
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

extension ModelProvider {
    /// Convenience: generate from a bare prompt.
    public func generate(
        prompt: String,
        system: String? = nil,
        options: GenerationOptions = GenerationOptions()
    ) async throws -> GenerationResponse {
        var messages: [ChatMessage] = []
        if let system {
            messages.append(.system(system))
        }
        messages.append(.user(prompt))
        return try await generate(GenerationRequest(messages: messages, options: options))
    }

    /// Default streaming implementation for providers without native
    /// streaming: performs one full generation and replays it as events.
    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await generate(request)
                    continuation.yield(.responseStarted(id: nil))
                    let text = response.text
                    if !text.isEmpty {
                        continuation.yield(.textDelta(text))
                    }
                    for call in response.toolCalls {
                        continuation.yield(.toolCallCompleted(call))
                    }
                    continuation.yield(.finished(reason: response.finishReason, usage: response.usage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
