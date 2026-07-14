import Foundation
import XCTest
@testable import SwiftAgentKit

final class AnthropicProviderTests: XCTestCase {
    // MARK: Request encoding

    func testSystemMessagesBecomeSystemField() {
        let request = GenerationRequest(messages: [
            .system("be helpful"),
            .user("hello"),
        ])
        let body = AnthropicWire.requestBody(model: "claude-opus-4-8", request: request, defaultMaxTokens: 4096, stream: false)
        XCTAssertEqual(body["system"], .string("be helpful"))
        XCTAssertEqual(body["max_tokens"], .int(4096))
        let messages = body["messages"]?.arrayValue
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?[0]["role"], .string("user"))
        XCTAssertEqual(messages?[0]["content"], .string("hello"))
    }

    func testToolResultsMergeIntoOneUserTurn() {
        let request = GenerationRequest(messages: [
            .user("check two things"),
            .assistant("", toolCalls: [
                ToolCall(id: "tu_1", name: "a", arguments: .object([:])),
                ToolCall(id: "tu_2", name: "b", arguments: .object([:])),
            ]),
            .tool(callID: "tu_1", name: "a", content: "result A"),
            .tool(callID: "tu_2", name: "b", content: "result B", isError: true),
        ])
        let body = AnthropicWire.requestBody(model: "m", request: request, defaultMaxTokens: 1024, stream: false)
        let messages = body["messages"]?.arrayValue
        XCTAssertEqual(messages?.count, 3)

        let assistant = messages?[1]
        XCTAssertEqual(assistant?["content"]?[0]?["type"], .string("tool_use"))
        XCTAssertEqual(assistant?["content"]?[0]?["id"], .string("tu_1"))
        XCTAssertEqual(assistant?["content"]?[1]?["id"], .string("tu_2"))

        // Both tool results must land in a single user message.
        let toolTurn = messages?[2]
        XCTAssertEqual(toolTurn?["role"], .string("user"))
        XCTAssertEqual(toolTurn?["content"]?[0]?["type"], .string("tool_result"))
        XCTAssertEqual(toolTurn?["content"]?[0]?["tool_use_id"], .string("tu_1"))
        XCTAssertEqual(toolTurn?["content"]?[1]?["tool_use_id"], .string("tu_2"))
        XCTAssertEqual(toolTurn?["content"]?[1]?["is_error"], .bool(true))
        XCTAssertNil(toolTurn?["content"]?[0]?["is_error"])
    }

    func testToolsAndToolChoiceEncoding() {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Weather",
            parameters: .object(properties: ["city": .string()])
        )
        let request = GenerationRequest(messages: [.user("x")], tools: [tool], toolChoice: .tool("get_weather"))
        let body = AnthropicWire.requestBody(model: "m", request: request, defaultMaxTokens: 1024, stream: false)
        XCTAssertEqual(body["tools"]?[0]?["name"], .string("get_weather"))
        XCTAssertEqual(body["tools"]?[0]?["input_schema"]?["type"], .string("object"))
        XCTAssertEqual(body["tool_choice"]?["type"], .string("tool"))
        XCTAssertEqual(body["tool_choice"]?["name"], .string("get_weather"))
    }

    func testJSONSchemaResponseFormatUsesOutputConfig() {
        let schema = JSONSchema.object(properties: ["title": .string()])
        let request = GenerationRequest(
            messages: [.user("x")],
            responseFormat: .jsonSchema(name: "out", schema: schema, strict: true)
        )
        let body = AnthropicWire.requestBody(model: "m", request: request, defaultMaxTokens: 1024, stream: false)
        let format = body["output_config"]?["format"]
        XCTAssertEqual(format?["type"], .string("json_schema"))
        XCTAssertEqual(format?["schema"]?["type"], .string("object"))
    }

    func testHeadersCarryAPIKeyAndVersion() async throws {
        let transport = MockTransport(json: #"""
        {"content": [{"type": "text", "text": "hi"}], "stop_reason": "end_turn",
         "usage": {"input_tokens": 2, "output_tokens": 1}}
        """#)
        let provider = AnthropicProvider(apiKey: "sk-ant-test", model: "claude-opus-4-8", transport: transport)
        _ = try await provider.generate(prompt: "hello")
        let sent = await transport.sentRequests
        XCTAssertEqual(sent[0].headers["x-api-key"], "sk-ant-test")
        XCTAssertEqual(sent[0].headers["anthropic-version"], "2023-06-01")
        XCTAssertTrue(sent[0].url.absoluteString.hasSuffix("/v1/messages"))
    }

    // MARK: Response decoding

    func testParseTextAndToolUseResponse() throws {
        let json = try JSONValue(parsing: #"""
        {"id": "msg_1", "content": [
            {"type": "text", "text": "Let me check."},
            {"type": "tool_use", "id": "tu_9", "name": "get_weather", "input": {"city": "Kyoto"}}
         ],
         "stop_reason": "tool_use",
         "usage": {"input_tokens": 30, "output_tokens": 12}}
        """#)
        let response = try AnthropicWire.parseResponse(json)
        XCTAssertEqual(response.text, "Let me check.")
        XCTAssertEqual(response.finishReason, .toolCalls)
        XCTAssertEqual(response.toolCalls, [
            ToolCall(id: "tu_9", name: "get_weather", arguments: ["city": "Kyoto"])
        ])
        XCTAssertEqual(response.usage, TokenUsage(inputTokens: 30, outputTokens: 12))
    }

    func testStopReasonMapping() {
        XCTAssertEqual(AnthropicWire.parseStopReason("end_turn"), .stop)
        XCTAssertEqual(AnthropicWire.parseStopReason("stop_sequence"), .stop)
        XCTAssertEqual(AnthropicWire.parseStopReason("tool_use"), .toolCalls)
        XCTAssertEqual(AnthropicWire.parseStopReason("max_tokens"), .length)
        XCTAssertEqual(AnthropicWire.parseStopReason("refusal"), .contentFilter)
        XCTAssertEqual(AnthropicWire.parseStopReason("pause_turn"), .other("pause_turn"))
    }

    // MARK: Streaming

    /// Renders (event, data) pairs as a spec-conformant SSE byte stream.
    private func sseStream(_ events: [(event: String, data: String)]) -> String {
        events.map { "event: \($0.event)\ndata: \($0.data)\n\n" }.joined()
    }

    /// Splits a string into fixed-size chunks to stress boundary handling.
    private func split(_ text: String, every size: Int) -> [String] {
        var chunks: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            let chunk = remaining.prefix(size)
            chunks.append(String(chunk))
            remaining = remaining.dropFirst(chunk.count)
        }
        return chunks
    }

    func testStreamParsesAnthropicEventSequence() async throws {
        let stream = sseStream([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_s1","usage":{"input_tokens":25,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        // Deliver in ragged 17-byte chunks: boundaries land mid-line, mid-JSON.
        let transport = MockTransport(sseChunks: split(stream, every: 17))
        let provider = AnthropicProvider(apiKey: "k", model: "claude-opus-4-8", transport: transport)

        var events: [StreamEvent] = []
        for try await event in provider.stream(GenerationRequest(messages: [.user("hi")])) {
            events.append(event)
        }

        XCTAssertEqual(events.first, .responseStarted(id: "msg_s1"))
        XCTAssertTrue(events.contains(.textDelta("Hello")))
        XCTAssertTrue(events.contains(.textDelta(" there")))
        XCTAssertEqual(
            events.last,
            .finished(reason: .stop, usage: TokenUsage(inputTokens: 25, outputTokens: 7))
        )
    }

    func testStreamAssemblesToolUseBlocks() async throws {
        let stream = sseStream([
            ("message_start", #"{"type":"message_start","message":{"id":"msg_t","usage":{"input_tokens":10}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_5","name":"search"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"q\":"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"mcp\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ])
        let transport = MockTransport(sseChunks: split(stream, every: 23))
        let provider = AnthropicProvider(apiKey: "k", model: "claude-opus-4-8", transport: transport)

        var events: [StreamEvent] = []
        for try await event in provider.stream(GenerationRequest(messages: [.user("x")])) {
            events.append(event)
        }

        XCTAssertTrue(events.contains(.toolCallStarted(index: 0, id: "tu_5", name: "search")))
        let completed = events.compactMap { event -> ToolCall? in
            if case .toolCallCompleted(let call) = event { return call }
            return nil
        }
        XCTAssertEqual(completed, [ToolCall(id: "tu_5", name: "search", arguments: ["q": "mcp"])])
        XCTAssertEqual(
            events.last,
            .finished(reason: .toolCalls, usage: TokenUsage(inputTokens: 10, outputTokens: 9))
        )
    }
}
