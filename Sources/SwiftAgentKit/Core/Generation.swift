import Foundation

// MARK: - Request

/// A provider-neutral generation request.
public struct GenerationRequest: Sendable {
    /// The conversation so far. The first message may be a system message.
    public var messages: [ChatMessage]
    /// Tools the model may call (definitions only; execution stays local).
    public var tools: [ToolDefinition]
    /// How the model may pick tools.
    public var toolChoice: ToolChoice
    /// Desired response format (free text, JSON object, or JSON Schema).
    public var responseFormat: ResponseFormat
    /// Sampling and transport options.
    public var options: GenerationOptions
    /// Overrides the provider's configured model for this request.
    public var model: String?

    /// Creates a request.
    public init(
        messages: [ChatMessage],
        tools: [ToolDefinition] = [],
        toolChoice: ToolChoice = .auto,
        responseFormat: ResponseFormat = .text,
        options: GenerationOptions = GenerationOptions(),
        model: String? = nil
    ) {
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.responseFormat = responseFormat
        self.options = options
        self.model = model
    }
}

/// Schema-level description of a callable tool, decoupled from its
/// implementation so it can cross the provider boundary.
public struct ToolDefinition: Sendable, Equatable {
    /// The tool name the model calls it by.
    public var name: String
    /// What the tool does, written for the model.
    public var description: String
    /// JSON Schema of the tool's arguments.
    public var parameters: JSONSchema

    /// Creates a definition.
    public init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Tool-selection policy.
public enum ToolChoice: Sendable, Equatable {
    /// The model decides whether to call tools (default).
    case auto
    /// The model must not call tools.
    case none
    /// The model must call at least one tool.
    case required
    /// The model must call the named tool.
    case tool(String)
}

/// Desired output shape.
public enum ResponseFormat: Sendable, Equatable {
    /// Free-form text (default).
    case text
    /// Any syntactically valid JSON object.
    case jsonObject
    /// JSON constrained by the given schema.
    case jsonSchema(name: String, schema: JSONSchema, strict: Bool)

    /// JSON constrained by the given schema, in strict mode.
    public static func jsonSchema(name: String, schema: JSONSchema) -> ResponseFormat {
        .jsonSchema(name: name, schema: schema, strict: true)
    }
}

/// Sampling and transport options shared by all providers.
public struct GenerationOptions: Sendable, Equatable {
    /// Sampling temperature, if the provider supports it.
    public var temperature: Double?
    /// Nucleus-sampling probability mass, if supported.
    public var topP: Double?
    /// Maximum tokens to generate.
    public var maxTokens: Int?
    /// Sequences that stop generation.
    public var stopSequences: [String]?
    /// Extra top-level fields merged into the provider request body —
    /// an escape hatch for provider-specific parameters.
    public var extraBody: [String: JSONValue]
    /// Extra HTTP headers sent with the request.
    public var extraHeaders: [String: String]

    /// Creates options; everything defaults to "provider default".
    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String]? = nil,
        extraBody: [String: JSONValue] = [:],
        extraHeaders: [String: String] = [:]
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.extraBody = extraBody
        self.extraHeaders = extraHeaders
    }
}

// MARK: - Response

/// A completed model response.
public struct GenerationResponse: Sendable {
    /// The assistant message (text content and/or tool calls).
    public var message: ChatMessage
    /// Why generation stopped.
    public var finishReason: FinishReason
    /// Token accounting, when the provider reports it.
    public var usage: TokenUsage
    /// The provider's raw response payload, for anything not mapped above.
    public var raw: JSONValue?

    /// Creates a response.
    public init(
        message: ChatMessage,
        finishReason: FinishReason,
        usage: TokenUsage = TokenUsage(),
        raw: JSONValue? = nil
    ) {
        self.message = message
        self.finishReason = finishReason
        self.usage = usage
        self.raw = raw
    }

    /// Text content of the assistant message.
    public var text: String { message.text }

    /// Tool calls requested by the assistant.
    public var toolCalls: [ToolCall] { message.toolCalls }
}

/// Why the model stopped generating.
public enum FinishReason: Sendable, Equatable {
    /// Natural end of the response.
    case stop
    /// The model wants tools executed.
    case toolCalls
    /// The token limit was hit; output may be truncated.
    case length
    /// The provider filtered or refused the content.
    case contentFilter
    /// A provider-specific reason not mapped above.
    case other(String)
}

/// Token accounting for one or more requests.
public struct TokenUsage: Sendable, Equatable {
    /// Tokens consumed by the prompt.
    public var inputTokens: Int
    /// Tokens produced by the model.
    public var outputTokens: Int

    /// Input plus output tokens.
    public var totalTokens: Int { inputTokens + outputTokens }

    /// Creates a usage record; zero means "not reported".
    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Accumulates usage across multiple requests (e.g. agent steps).
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }

    /// In-place variant of `+`.
    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

// MARK: - Streaming

/// Incremental events produced while streaming a response.
public enum StreamEvent: Sendable, Equatable {
    /// The provider acknowledged the request (carries a response ID if known).
    case responseStarted(id: String?)
    /// A fragment of assistant text.
    case textDelta(String)
    /// A fragment of model reasoning/thinking, for providers that expose it.
    case reasoningDelta(String)
    /// The model started a tool call.
    case toolCallStarted(index: Int, id: String, name: String)
    /// A fragment of a tool call's JSON arguments.
    case toolCallDelta(index: Int, argumentsFragment: String)
    /// A tool call's arguments are complete and parsed.
    case toolCallCompleted(ToolCall)
    /// The response finished.
    case finished(reason: FinishReason, usage: TokenUsage)
}

// MARK: - Errors

/// Errors thrown by SwiftAgentKit.
public enum AgentKitError: Error, Sendable, CustomStringConvertible {
    /// The provider returned a non-success HTTP status.
    case httpError(statusCode: Int, message: String?)
    /// A network/transport-level failure.
    case transport(String)
    /// The provider payload could not be interpreted.
    case decodingFailed(String)
    /// The response contained no usable content.
    case emptyResponse
    /// The model called a tool that is not registered.
    case toolNotFound(String)
    /// Tool arguments failed to decode into the tool's input type.
    case invalidToolArguments(tool: String, underlying: String)
    /// Schema inference failed; see the message for the fix.
    case schemaInference(String)
    /// Structured output could not be decoded into the target type.
    case objectDecodingFailed(underlying: String, rawText: String)
    /// A JSON-RPC error returned by an MCP server.
    case mcpError(code: Int, message: String)
    /// The MCP transport closed while requests were in flight.
    case transportClosed
    /// The request uses a feature this provider does not support.
    case unsupported(String)

    public var description: String {
        switch self {
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message ?? "no error body")"
        case .transport(let message):
            return "Transport error: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode provider response: \(message)"
        case .emptyResponse:
            return "The provider returned an empty response"
        case .toolNotFound(let name):
            return "No tool registered with name '\(name)'"
        case .invalidToolArguments(let tool, let underlying):
            return "Invalid arguments for tool '\(tool)': \(underlying)"
        case .schemaInference(let message):
            return "Schema inference failed: \(message)"
        case .objectDecodingFailed(let underlying, let rawText):
            return "Failed to decode structured output: \(underlying). Raw text: \(rawText)"
        case .mcpError(let code, let message):
            return "MCP error \(code): \(message)"
        case .transportClosed:
            return "The MCP transport was closed"
        case .unsupported(let message):
            return "Unsupported: \(message)"
        }
    }
}
