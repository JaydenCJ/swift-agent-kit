import Foundation
@testable import SwiftAgentKit

/// An `HTTPTransport` that replays canned responses and records requests.
actor MockTransport: HTTPTransport {
    private(set) var sentRequests: [HTTPRequest] = []
    private var responses: [HTTPResponse]
    private var streamChunks: [[Data]]

    init(responses: [HTTPResponse] = [], streamChunks: [[Data]] = []) {
        self.responses = responses
        self.streamChunks = streamChunks
    }

    /// Convenience: a single 200 JSON response.
    init(json: String, statusCode: Int = 200) {
        self.responses = [HTTPResponse(statusCode: statusCode, body: Data(json.utf8))]
        self.streamChunks = []
    }

    /// Convenience: a single SSE stream split into the given chunks.
    init(sseChunks: [String]) {
        self.responses = []
        self.streamChunks = [sseChunks.map { Data($0.utf8) }]
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sentRequests.append(request)
        guard !responses.isEmpty else {
            throw AgentKitError.transport("MockTransport has no responses left")
        }
        return responses.removeFirst()
    }

    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        sentRequests.append(request)
        guard !streamChunks.isEmpty else {
            throw AgentKitError.transport("MockTransport has no stream chunks left")
        }
        let chunks = streamChunks.removeFirst()
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    /// The decoded JSON body of the request at `index`.
    func requestBody(at index: Int = 0) throws -> JSONValue {
        guard sentRequests.indices.contains(index), let body = sentRequests[index].body else {
            throw AgentKitError.transport("No request body at index \(index)")
        }
        return try JSONValue(data: body)
    }
}

/// A `ModelProvider` that replays a fixed sequence of responses and records
/// the requests it receives. Thread-safe.
final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let name = "scripted"

    private let lock = NSLock()
    private var responses: [GenerationResponse]
    private var recorded: [GenerationRequest] = []

    init(responses: [GenerationResponse]) {
        self.responses = responses
    }

    var requests: [GenerationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func generate(_ request: GenerationRequest) async throws -> GenerationResponse {
        try lock.withLock {
            recorded.append(request)
            guard !responses.isEmpty else {
                throw AgentKitError.emptyResponse
            }
            return responses.removeFirst()
        }
    }
}

/// A lock-protected mutable box, for capturing state in @Sendable closures.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        self.storage = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var value: T {
        withLock { $0 }
    }
}

extension GenerationResponse {
    /// A plain-text assistant response.
    static func text(_ text: String, usage: TokenUsage = TokenUsage()) -> GenerationResponse {
        GenerationResponse(message: .assistant(text), finishReason: .stop, usage: usage)
    }

    /// An assistant response requesting tool calls.
    static func toolCalls(_ calls: [ToolCall], usage: TokenUsage = TokenUsage()) -> GenerationResponse {
        GenerationResponse(
            message: .assistant("", toolCalls: calls),
            finishReason: .toolCalls,
            usage: usage
        )
    }
}
