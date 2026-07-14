import Foundation

/// A single message in a conversation, in a provider-neutral shape.
///
/// The same `ChatMessage` array drives OpenAI-compatible servers, Anthropic,
/// Apple Foundation Models and anything else that implements
/// ``ModelProvider`` — providers translate to their own wire formats.
public struct ChatMessage: Sendable, Equatable, Codable {
    /// Who authored the message.
    public enum Role: String, Sendable, Codable, CaseIterable {
        case system
        case user
        case assistant
        case tool
    }

    /// The author of this message.
    public var role: Role

    /// The message body as an ordered list of content parts.
    public var content: [ContentPart]

    /// Tool invocations requested by the assistant (assistant role only).
    public var toolCalls: [ToolCall]

    /// The ID of the tool call this message answers (tool role only).
    public var toolCallID: String?

    /// The tool name this message answers (tool role only), or a speaker name.
    public var name: String?

    /// Whether a tool-role message reports a failed execution.
    public var isToolError: Bool?

    /// Creates a message. Prefer the role-specific factories below for
    /// common shapes.
    public init(
        role: Role,
        content: [ContentPart] = [],
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil,
        name: String? = nil,
        isToolError: Bool? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
        self.isToolError = isToolError
    }

    /// All text parts of the message, joined with newlines.
    public var text: String {
        content.compactMap { part in
            if case .text(let value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: Conveniences

    /// A system message with plain-text content.
    public static func system(_ text: String) -> ChatMessage {
        ChatMessage(role: .system, content: [.text(text)])
    }

    /// A user message with plain-text content.
    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: [.text(text)])
    }

    /// A user message with mixed content parts (text and images).
    public static func user(_ parts: [ContentPart]) -> ChatMessage {
        ChatMessage(role: .user, content: parts)
    }

    /// An assistant message, optionally carrying tool calls.
    public static func assistant(_ text: String, toolCalls: [ToolCall] = []) -> ChatMessage {
        ChatMessage(role: .assistant, content: text.isEmpty ? [] : [.text(text)], toolCalls: toolCalls)
    }

    /// A tool-result message answering the tool call `callID`.
    public static func tool(
        callID: String,
        name: String? = nil,
        content: String,
        isError: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            role: .tool,
            content: [.text(content)],
            toolCallID: callID,
            name: name,
            isToolError: isError ? true : nil
        )
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
        case isToolError = "is_error"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        // Accept both a bare string and a list of parts for `content`.
        if let text = try? container.decode(String.self, forKey: .content) {
            content = [.text(text)]
        } else {
            content = try container.decodeIfPresent([ContentPart].self, forKey: .content) ?? []
        }
        toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isToolError = try container.decodeIfPresent(Bool.self, forKey: .isToolError)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        if !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(isToolError, forKey: .isToolError)
    }
}

/// One piece of message content — text or an image.
public enum ContentPart: Sendable, Equatable, Codable {
    case text(String)
    case imageURL(String)
    case imageData(Data, mimeType: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case url
        case data
        case mimeType = "mime_type"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decode(String.self, forKey: .text))
        case "image_url":
            self = .imageURL(try container.decode(String.self, forKey: .url))
        case "image_data":
            let base64 = try container.decode(String.self, forKey: .data)
            guard let data = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data, in: container,
                    debugDescription: "Invalid base64 image data"
                )
            }
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .imageData(data, mimeType: mimeType)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown content part type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(url, forKey: .url)
        case .imageData(let data, let mimeType):
            try container.encode("image_data", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

/// A tool invocation requested by the model.
public struct ToolCall: Sendable, Equatable, Codable {
    /// Provider-assigned call identifier; echoed back in the tool result.
    public var id: String
    /// The tool name to invoke.
    public var name: String
    /// Parsed tool arguments.
    public var arguments: JSONValue

    /// Creates a tool call.
    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}
