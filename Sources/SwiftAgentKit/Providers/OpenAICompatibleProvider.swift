import Foundation

/// A provider for any server that speaks the OpenAI Chat Completions API —
/// which today means most of the local-model world: Ollama (including MLX
/// models since v0.19), llama.cpp's `llama-server`, LM Studio, vLLM,
/// osaurus, apfel … plus OpenAI itself and countless proxies.
///
/// ```swift
/// // Local model via Ollama:
/// let local = OpenAICompatibleProvider.ollama(model: "qwen3")
///
/// // Cloud:
/// let cloud = OpenAICompatibleProvider.openAI(model: "gpt-4o-mini", apiKey: key)
/// ```
public struct OpenAICompatibleProvider: ModelProvider {
    /// Provider name used in logs; preset factories set a specific one.
    public let name: String
    /// Base URL up to and including the API version, e.g.
    /// `http://localhost:11434/v1`.
    public let baseURL: URL
    /// The default model id sent with each request.
    public let model: String
    /// Bearer token, sent as `Authorization: Bearer …` when present.
    public let apiKey: String?
    /// Extra HTTP headers sent with every request.
    public let extraHeaders: [String: String]
    let transport: any HTTPTransport

    /// Creates a provider for any OpenAI-compatible endpoint.
    public init(
        name: String = "openai-compatible",
        baseURL: URL,
        model: String,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.transport = transport
    }

    // MARK: Presets

    /// OpenAI's hosted API.
    public static func openAI(
        model: String,
        apiKey: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            name: "openai",
            baseURL: URL(string: "https://api.openai.com/v1")!,
            model: model,
            apiKey: apiKey,
            transport: transport
        )
    }

    /// A local Ollama server (also serves MLX models on Apple silicon).
    public static func ollama(
        model: String,
        baseURL: URL = URL(string: "http://localhost:11434/v1")!,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(name: "ollama", baseURL: baseURL, model: model, transport: transport)
    }

    /// A local `llama.cpp` `llama-server` instance.
    public static func llamaCpp(
        model: String = "default",
        baseURL: URL = URL(string: "http://localhost:8080/v1")!,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(name: "llama.cpp", baseURL: baseURL, model: model, transport: transport)
    }

    /// A local LM Studio server.
    public static func lmStudio(
        model: String,
        baseURL: URL = URL(string: "http://localhost:1234/v1")!,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(name: "lmstudio", baseURL: baseURL, model: model, transport: transport)
    }

    /// A vLLM server (`vllm serve …`), which exposes an OpenAI-compatible
    /// API on port 8000 by default.
    public static func vllm(
        model: String,
        baseURL: URL = URL(string: "http://localhost:8000/v1")!,
        apiKey: String? = nil,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            name: "vllm",
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            transport: transport
        )
    }

    // Any other OpenAI-compatible server (osaurus, apfel, proxies, …) works
    // through the designated initializer with the server's base URL.

    // MARK: Requests

    func makeHTTPRequest(_ request: GenerationRequest, stream: Bool) throws -> HTTPRequest {
        let body = OpenAIWire.requestBody(
            model: request.model ?? model,
            request: request,
            stream: stream
        )
        var headers = [
            "Content-Type": "application/json",
        ]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        if stream {
            headers["Accept"] = "text/event-stream"
        }
        for (name, value) in extraHeaders { headers[name] = value }
        for (name, value) in request.options.extraHeaders { headers[name] = value }
        return HTTPRequest(
            url: baseURL.appendingPathComponent("chat/completions"),
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
                message: OpenAIWire.errorMessage(from: httpResponse.body)
            )
        }
        let json = try JSONValue(data: httpResponse.body)
        return try OpenAIWire.parseResponse(json)
    }

    public func stream(_ request: GenerationRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let httpRequest = try makeHTTPRequest(request, stream: true)
                    let byteStream = try await transport.stream(httpRequest)
                    var parser = SSEParser()
                    var state = OpenAIWire.StreamState()

                    for try await chunk in byteStream {
                        for sse in parser.feed(chunk) {
                            if sse.data == "[DONE]" { continue }
                            let json = try JSONValue(parsing: sse.data)
                            for event in OpenAIWire.parseChunk(json, state: &state) {
                                continuation.yield(event)
                            }
                        }
                    }
                    if let sse = parser.finish(), sse.data != "[DONE]",
                       let json = try? JSONValue(parsing: sse.data) {
                        for event in OpenAIWire.parseChunk(json, state: &state) {
                            continuation.yield(event)
                        }
                    }
                    for event in state.finalEvents() {
                        continuation.yield(event)
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

/// Pure functions translating between SwiftAgentKit types and the OpenAI
/// Chat Completions wire format. Kept separate so they are unit-testable
/// without any transport.
enum OpenAIWire {
    // MARK: Encoding

    static func requestBody(model: String, request: GenerationRequest, stream: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(request.messages.map { encodeMessage($0) }),
        ]
        if stream {
            body["stream"] = .bool(true)
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters.value,
                    ]),
                ])
            })
            switch request.toolChoice {
            case .auto:
                break
            case .none:
                body["tool_choice"] = .string("none")
            case .required:
                body["tool_choice"] = .string("required")
            case .tool(let name):
                body["tool_choice"] = .object([
                    "type": .string("function"),
                    "function": .object(["name": .string(name)]),
                ])
            }
        }
        switch request.responseFormat {
        case .text:
            break
        case .jsonObject:
            body["response_format"] = .object(["type": .string("json_object")])
        case .jsonSchema(let name, let schema, let strict):
            body["response_format"] = .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string(name),
                    "schema": schema.value,
                    "strict": .bool(strict),
                ]),
            ])
        }
        let options = request.options
        if let temperature = options.temperature { body["temperature"] = .double(temperature) }
        if let topP = options.topP { body["top_p"] = .double(topP) }
        if let maxTokens = options.maxTokens { body["max_tokens"] = .int(maxTokens) }
        if let stop = options.stopSequences, !stop.isEmpty {
            body["stop"] = .array(stop.map { .string($0) })
        }
        for (key, value) in options.extraBody { body[key] = value }
        return .object(body)
    }

    static func encodeMessage(_ message: ChatMessage) -> JSONValue {
        var encoded: [String: JSONValue] = [
            "role": .string(message.role.rawValue)
        ]
        switch message.role {
        case .tool:
            encoded["content"] = .string(message.text)
            if let callID = message.toolCallID {
                encoded["tool_call_id"] = .string(callID)
            }
        case .assistant:
            if !message.text.isEmpty {
                encoded["content"] = .string(message.text)
            } else if message.toolCalls.isEmpty {
                encoded["content"] = .string("")
            }
            if !message.toolCalls.isEmpty {
                encoded["tool_calls"] = .array(message.toolCalls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(call.arguments.canonicalJSONString()),
                        ]),
                    ])
                })
            }
        case .system, .user:
            encoded["content"] = encodeContent(message.content)
        }
        if let name = message.name, message.role != .tool {
            encoded["name"] = .string(name)
        }
        return .object(encoded)
    }

    private static func encodeContent(_ parts: [ContentPart]) -> JSONValue {
        // Single text part collapses to a bare string — maximally compatible.
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
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string(url)]),
                ])
            case .imageData(let data, let mimeType):
                let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
                return .object([
                    "type": .string("image_url"),
                    "image_url": .object(["url": .string(dataURL)]),
                ])
            }
        })
    }

    // MARK: Decoding

    static func errorMessage(from body: Data) -> String? {
        guard let json = try? JSONValue(data: body) else {
            return String(data: body, encoding: .utf8)
        }
        return json["error"]?["message"]?.stringValue
            ?? json["error"]?.stringValue
            ?? String(data: body, encoding: .utf8)
    }

    static func parseResponse(_ json: JSONValue) throws -> GenerationResponse {
        guard let choice = json["choices"]?[0] else {
            throw AgentKitError.decodingFailed("Response has no choices: \(json.canonicalJSONString())")
        }
        let messageJSON = choice["message"]
        var content: [ContentPart] = []
        if let text = messageJSON?["content"]?.stringValue, !text.isEmpty {
            content.append(.text(text))
        }
        var toolCalls: [ToolCall] = []
        if let calls = messageJSON?["tool_calls"]?.arrayValue {
            for (index, call) in calls.enumerated() {
                let id = call["id"]?.stringValue ?? "call_\(index)"
                guard let name = call["function"]?["name"]?.stringValue else { continue }
                let rawArguments = call["function"]?["arguments"]?.stringValue ?? "{}"
                let arguments = (try? JSONValue(parsing: rawArguments)) ?? .string(rawArguments)
                toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
            }
        }
        let message = ChatMessage(role: .assistant, content: content, toolCalls: toolCalls)
        let finishReason = parseFinishReason(
            choice["finish_reason"]?.stringValue,
            hasToolCalls: !toolCalls.isEmpty
        )
        return GenerationResponse(
            message: message,
            finishReason: finishReason,
            usage: parseUsage(json["usage"]),
            raw: json
        )
    }

    static func parseFinishReason(_ raw: String?, hasToolCalls: Bool) -> FinishReason {
        switch raw {
        case "stop": return hasToolCalls ? .toolCalls : .stop
        case "tool_calls", "function_call": return .toolCalls
        case "length": return .length
        case "content_filter": return .contentFilter
        case nil: return hasToolCalls ? .toolCalls : .stop
        case .some(let other): return .other(other)
        }
    }

    static func parseUsage(_ json: JSONValue?) -> TokenUsage {
        TokenUsage(
            inputTokens: json?["prompt_tokens"]?.intValue ?? 0,
            outputTokens: json?["completion_tokens"]?.intValue ?? 0
        )
    }

    // MARK: Stream decoding

    /// Mutable state carried across streamed chunks.
    struct StreamState {
        var assembler = ToolCallAssembler()
        var finishReason: FinishReason?
        var usage = TokenUsage()
        var startedEmitted = false

        /// Events to emit after the last chunk: completed tool calls and
        /// the terminal `.finished`.
        func finalEvents() -> [StreamEvent] {
            var events: [StreamEvent] = assembler.completedCalls().map { .toolCallCompleted($0) }
            let hasToolCalls = assembler.hasCalls
            let reason = finishReason ?? (hasToolCalls ? .toolCalls : .stop)
            events.append(.finished(reason: reason, usage: usage))
            return events
        }
    }

    /// Parses one streamed chunk object into zero or more events.
    static func parseChunk(_ json: JSONValue, state: inout StreamState) -> [StreamEvent] {
        var events: [StreamEvent] = []
        if !state.startedEmitted {
            state.startedEmitted = true
            events.append(.responseStarted(id: json["id"]?.stringValue))
        }
        if let usage = json["usage"], !usage.isNull {
            state.usage = parseUsage(usage)
        }
        guard let choice = json["choices"]?[0] else {
            return events
        }
        if let finish = choice["finish_reason"]?.stringValue {
            state.finishReason = parseFinishReason(finish, hasToolCalls: state.assembler.hasCalls)
        }
        guard let delta = choice["delta"] else {
            return events
        }
        if let text = delta["content"]?.stringValue, !text.isEmpty {
            events.append(.textDelta(text))
        }
        if let reasoning = delta["reasoning_content"]?.stringValue, !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let calls = delta["tool_calls"]?.arrayValue {
            for (position, call) in calls.enumerated() {
                let index = call["index"]?.intValue ?? position
                let fragment = call["function"]?["arguments"]?.stringValue
                let started = state.assembler.apply(
                    index: index,
                    id: call["id"]?.stringValue,
                    name: call["function"]?["name"]?.stringValue,
                    argumentsFragment: fragment
                )
                if started, let identity = state.assembler.identity(at: index) {
                    events.append(.toolCallStarted(index: index, id: identity.id, name: identity.name))
                }
                if let fragment, !fragment.isEmpty {
                    events.append(.toolCallDelta(index: index, argumentsFragment: fragment))
                }
            }
        }
        return events
    }
}
