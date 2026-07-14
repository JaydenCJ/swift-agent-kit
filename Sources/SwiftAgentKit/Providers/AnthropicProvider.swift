import Foundation

/// A provider for the Anthropic Messages API (`/v1/messages`).
///
/// ```swift
/// let claude = AnthropicProvider(
///     apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!,
///     model: "claude-opus-4-8"
/// )
/// ```
public struct AnthropicProvider: ModelProvider {
    /// Provider name used in logs.
    public let name = "anthropic"
    /// API origin (default `https://api.anthropic.com`).
    public let baseURL: URL
    /// The default model id sent with each request.
    public let model: String
    /// The API key, sent as the `x-api-key` header.
    public let apiKey: String
    /// The `anthropic-version` header value.
    public let apiVersion: String
    /// Default `max_tokens` when the request doesn't set one — the
    /// Messages API requires it.
    public let defaultMaxTokens: Int
    let transport: any HTTPTransport

    /// Creates a Messages API provider.
    public init(
        apiKey: String,
        model: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiVersion: String = "2023-06-01",
        defaultMaxTokens: Int = 4096,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.defaultMaxTokens = defaultMaxTokens
        self.transport = transport
    }

    func makeHTTPRequest(_ request: GenerationRequest, stream: Bool) throws -> HTTPRequest {
        let body = AnthropicWire.requestBody(
            model: request.model ?? model,
            request: request,
            defaultMaxTokens: defaultMaxTokens,
            stream: stream
        )
        var headers = [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": apiVersion,
        ]
        if stream {
            headers["Accept"] = "text/event-stream"
        }
        for (name, value) in request.options.extraHeaders { headers[name] = value }
        return HTTPRequest(
            url: baseURL.appendingPathComponent("v1/messages"),
            method: "POST",
            headers: headers,
            body: try body.jsonData()
        )
    }

    public func generate(_ request: GenerationRequest) async throws -> GenerationResponse {
        let httpRequest = try makeHTTPRequest(request, stream: false)
        let httpResponse = try await transport.send(httpRequest)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AgentKitError.httpError(
                statusCode: httpResponse.statusCode,
                message: AnthropicWire.errorMessage(from: httpResponse.body)
            )
        }
        let json = try JSONValue(data: httpResponse.body)
        return try AnthropicWire.parseResponse(json)
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let httpRequest = try makeHTTPRequest(request, stream: true)
                    let byteStream = try await transport.stream(httpRequest)
                    var parser = SSEParser()
                    var state = AnthropicWire.StreamState()

                    for try await chunk in byteStream {
                        for sse in parser.feed(chunk) {
                            let json = try JSONValue(parsing: sse.data)
                            for event in AnthropicWire.parseStreamEvent(json, state: &state) {
                                continuation.yield(event)
                            }
                        }
                    }
                    if let sse = parser.finish(), let json = try? JSONValue(parsing: sse.data) {
                        for event in AnthropicWire.parseStreamEvent(json, state: &state) {
                            continuation.yield(event)
                        }
                    }
                    if !state.finished {
                        continuation.yield(.finished(reason: state.finishReason ?? .stop, usage: state.usage))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Wire format

/// Pure functions translating between SwiftAgentKit types and the Anthropic
/// Messages API wire format.
enum AnthropicWire {
    // MARK: Encoding

    static func requestBody(
        model: String,
        request: GenerationRequest,
        defaultMaxTokens: Int,
        stream: Bool
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .int(request.options.maxTokens ?? defaultMaxTokens),
        ]
        if stream {
            body["stream"] = .bool(true)
        }

        // System messages become the top-level `system` field.
        let systemText = request.messages
            .filter { $0.role == .system }
            .map { $0.text }
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            body["system"] = .string(systemText)
        }

        body["messages"] = .array(encodeMessages(request.messages))

        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters.value,
                ])
            })
            switch request.toolChoice {
            case .auto:
                break
            case .none:
                body["tool_choice"] = .object(["type": .string("none")])
            case .required:
                body["tool_choice"] = .object(["type": .string("any")])
            case .tool(let name):
                body["tool_choice"] = .object(["type": .string("tool"), "name": .string(name)])
            }
        }

        switch request.responseFormat {
        case .text, .jsonObject:
            break
        case .jsonSchema(_, let schema, _):
            body["output_config"] = .object([
                "format": .object([
                    "type": .string("json_schema"),
                    "schema": schema.value,
                ]),
            ])
        }

        let options = request.options
        if let temperature = options.temperature { body["temperature"] = .double(temperature) }
        if let topP = options.topP { body["top_p"] = .double(topP) }
        if let stop = options.stopSequences, !stop.isEmpty {
            body["stop_sequences"] = .array(stop.map { .string($0) })
        }
        for (key, value) in options.extraBody { body[key] = value }
        return .object(body)
    }

    /// Maps neutral messages onto Anthropic's user/assistant alternation:
    /// system messages are handled separately; tool results become
    /// `tool_result` blocks in a user turn, and consecutive tool results
    /// merge into a single user message as the API requires.
    static func encodeMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        var encoded: [JSONValue] = []
        var pendingToolResults: [JSONValue] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            encoded.append(.object([
                "role": .string("user"),
                "content": .array(pendingToolResults),
            ]))
            pendingToolResults = []
        }

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .tool:
                var block: [String: JSONValue] = [
                    "type": .string("tool_result"),
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.text),
                ]
                if message.isToolError == true {
                    block["is_error"] = .bool(true)
                }
                pendingToolResults.append(.object(block))
            case .user:
                flushToolResults()
                encoded.append(.object([
                    "role": .string("user"),
                    "content": encodeContent(message.content),
                ]))
            case .assistant:
                flushToolResults()
                var blocks: [JSONValue] = []
                for part in message.content {
                    if case .text(let text) = part, !text.isEmpty {
                        blocks.append(.object(["type": .string("text"), "text": .string(text)]))
                    }
                }
                for call in message.toolCalls {
                    blocks.append(.object([
                        "type": .string("tool_use"),
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": call.arguments,
                    ]))
                }
                if blocks.isEmpty {
                    blocks.append(.object(["type": .string("text"), "text": .string("")]))
                }
                encoded.append(.object([
                    "role": .string("assistant"),
                    "content": .array(blocks),
                ]))
            }
        }
        flushToolResults()
        return encoded
    }

    private static func encodeContent(_ parts: [ContentPart]) -> JSONValue {
        if parts.count == 1, case .text(let text) = parts[0] {
            return .string(text)
        }
        if parts.isEmpty {
            return .string("")
        }
        return .array(parts.map { part in
            switch part {
            case .text(let text):
                return .object(["type": .string("text"), "text": .string(text)])
            case .imageURL(let url):
                return .object([
                    "type": .string("image"),
                    "source": .object(["type": .string("url"), "url": .string(url)]),
                ])
            case .imageData(let data, let mimeType):
                return .object([
                    "type": .string("image"),
                    "source": .object([
                        "type": .string("base64"),
                        "media_type": .string(mimeType),
                        "data": .string(data.base64EncodedString()),
                    ]),
                ])
            }
        })
    }

    // MARK: Decoding

    static func errorMessage(from body: Data) -> String? {
        guard let json = try? JSONValue(data: body) else {
            return String(data: body, encoding: .utf8)
        }
        return json["error"]?["message"]?.stringValue ?? String(data: body, encoding: .utf8)
    }

    static func parseResponse(_ json: JSONValue) throws -> GenerationResponse {
        guard let blocks = json["content"]?.arrayValue else {
            throw AgentKitError.decodingFailed("Response has no content: \(json.canonicalJSONString())")
        }
        var content: [ContentPart] = []
        var toolCalls: [ToolCall] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    content.append(.text(text))
                }
            case "tool_use":
                toolCalls.append(ToolCall(
                    id: block["id"]?.stringValue ?? "",
                    name: block["name"]?.stringValue ?? "",
                    arguments: block["input"] ?? .object([:])
                ))
            default:
                continue // thinking blocks etc.
            }
        }
        let message = ChatMessage(role: .assistant, content: content, toolCalls: toolCalls)
        return GenerationResponse(
            message: message,
            finishReason: parseStopReason(json["stop_reason"]?.stringValue),
            usage: parseUsage(json["usage"]),
            raw: json
        )
    }

    static func parseStopReason(_ raw: String?) -> FinishReason {
        switch raw {
        case "end_turn", "stop_sequence": return .stop
        case "tool_use": return .toolCalls
        case "max_tokens": return .length
        case "refusal": return .contentFilter
        case nil: return .stop
        case .some(let other): return .other(other)
        }
    }

    static func parseUsage(_ json: JSONValue?) -> TokenUsage {
        TokenUsage(
            inputTokens: json?["input_tokens"]?.intValue ?? 0,
            outputTokens: json?["output_tokens"]?.intValue ?? 0
        )
    }

    // MARK: Stream decoding

    struct StreamState {
        var assembler = ToolCallAssembler()
        /// Indices of content blocks that are tool_use blocks.
        var toolBlockIndices: Set<Int> = []
        var finishReason: FinishReason?
        var usage = TokenUsage()
        var finished = false
    }

    /// Parses one Anthropic SSE event payload into zero or more events.
    static func parseStreamEvent(_ json: JSONValue, state: inout StreamState) -> [StreamEvent] {
        switch json["type"]?.stringValue {
        case "message_start":
            state.usage = parseUsage(json["message"]?["usage"])
            return [.responseStarted(id: json["message"]?["id"]?.stringValue)]

        case "content_block_start":
            guard let index = json["index"]?.intValue,
                  let block = json["content_block"] else { return [] }
            if block["type"]?.stringValue == "tool_use" {
                let id = block["id"]?.stringValue ?? ""
                let name = block["name"]?.stringValue ?? ""
                state.toolBlockIndices.insert(index)
                state.assembler.apply(index: index, id: id, name: name, argumentsFragment: nil)
                return [.toolCallStarted(index: index, id: id, name: name)]
            }
            return []

        case "content_block_delta":
            guard let delta = json["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                if let text = delta["text"]?.stringValue, !text.isEmpty {
                    return [.textDelta(text)]
                }
            case "thinking_delta":
                if let text = delta["thinking"]?.stringValue, !text.isEmpty {
                    return [.reasoningDelta(text)]
                }
            case "input_json_delta":
                if let index = json["index"]?.intValue,
                   let fragment = delta["partial_json"]?.stringValue, !fragment.isEmpty {
                    state.assembler.apply(index: index, id: nil, name: nil, argumentsFragment: fragment)
                    return [.toolCallDelta(index: index, argumentsFragment: fragment)]
                }
            default:
                break
            }
            return []

        case "content_block_stop":
            guard let index = json["index"]?.intValue,
                  state.toolBlockIndices.contains(index) else { return [] }
            state.toolBlockIndices.remove(index)
            // The block is complete: emit the assembled call for this index.
            let calls = state.assembler.completedCalls()
            if let identity = state.assembler.identity(at: index),
               let call = calls.first(where: { $0.id == identity.id || $0.name == identity.name }) {
                return [.toolCallCompleted(call)]
            }
            return []

        case "message_delta":
            if let stop = json["delta"]?["stop_reason"]?.stringValue {
                state.finishReason = parseStopReason(stop)
            }
            if let output = json["usage"]?["output_tokens"]?.intValue {
                state.usage.outputTokens = output
            }
            return []

        case "message_stop":
            state.finished = true
            return [.finished(reason: state.finishReason ?? .stop, usage: state.usage)]

        case "error":
            // Surfaced as a terminal finished event with the reason attached.
            state.finished = true
            let message = json["error"]?["message"]?.stringValue ?? "unknown stream error"
            return [.finished(reason: .other("error: \(message)"), usage: state.usage)]

        default: // ping etc.
            return []
        }
    }
}
