import Foundation
import XCTest
@testable import SwiftAgentKit

final class OpenAIProviderTests: XCTestCase {
    // MARK: Presets

    func testPresetEndpointsAndNames() {
        XCTAssertEqual(
            OpenAICompatibleProvider.openAI(model: "gpt-4o-mini", apiKey: "k").baseURL.absoluteString,
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleProvider.ollama(model: "qwen3").baseURL.absoluteString,
            "http://localhost:11434/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleProvider.llamaCpp().baseURL.absoluteString,
            "http://localhost:8080/v1"
        )
        XCTAssertEqual(
            OpenAICompatibleProvider.lmStudio(model: "m").baseURL.absoluteString,
            "http://localhost:1234/v1"
        )
        let vllm = OpenAICompatibleProvider.vllm(model: "m")
        XCTAssertEqual(vllm.baseURL.absoluteString, "http://localhost:8000/v1")
        XCTAssertEqual(vllm.name, "vllm")
    }

    // MARK: Request encoding

    func testRequestBodyBasics() {
        let request = GenerationRequest(
            messages: [.system("be brief"), .user("hi")],
            options: GenerationOptions(temperature: 0.2, maxTokens: 128)
        )
        let body = OpenAIWire.requestBody(model: "qwen3", request: request, stream: false)
        XCTAssertEqual(body["model"], .string("qwen3"))
        XCTAssertEqual(body["temperature"], .double(0.2))
        XCTAssertEqual(body["max_tokens"], .int(128))
        XCTAssertNil(body["stream"])
        XCTAssertEqual(body["messages"]?[0]?["role"], .string("system"))
        XCTAssertEqual(body["messages"]?[0]?["content"], .string("be brief"))
        XCTAssertEqual(body["messages"]?[1]?["content"], .string("hi"))
    }

    func testRequestBodyEncodesTools() {
        let tool = ToolDefinition(
            name: "get_weather",
            description: "Weather for a city",
            parameters: .object(properties: ["city": .string()])
        )
        let request = GenerationRequest(messages: [.user("x")], tools: [tool], toolChoice: .required)
        let body = OpenAIWire.requestBody(model: "m", request: request, stream: false)
        let function = body["tools"]?[0]?["function"]
        XCTAssertEqual(body["tools"]?[0]?["type"], .string("function"))
        XCTAssertEqual(function?["name"], .string("get_weather"))
        XCTAssertEqual(function?["parameters"]?["type"], .string("object"))
        XCTAssertEqual(body["tool_choice"], .string("required"))
    }

    func testRequestBodyEncodesSpecificToolChoice() {
        let tool = ToolDefinition(name: "f", description: "", parameters: .any)
        let request = GenerationRequest(messages: [.user("x")], tools: [tool], toolChoice: .tool("f"))
        let body = OpenAIWire.requestBody(model: "m", request: request, stream: false)
        XCTAssertEqual(body["tool_choice"]?["function"]?["name"], .string("f"))
    }

    func testRequestBodyEncodesJSONSchemaResponseFormat() {
        let schema = JSONSchema.object(properties: ["title": .string()])
        let request = GenerationRequest(
            messages: [.user("x")],
            responseFormat: .jsonSchema(name: "output", schema: schema, strict: true)
        )
        let body = OpenAIWire.requestBody(model: "m", request: request, stream: false)
        let format = body["response_format"]
        XCTAssertEqual(format?["type"], .string("json_schema"))
        XCTAssertEqual(format?["json_schema"]?["name"], .string("output"))
        XCTAssertEqual(format?["json_schema"]?["strict"], .bool(true))
        XCTAssertEqual(format?["json_schema"]?["schema"]?["type"], .string("object"))
    }

    func testRequestBodyRoundTripsAssistantToolCallsAndResults() {
        let call = ToolCall(id: "call_7", name: "lookup", arguments: ["q": "swift"])
        let request = GenerationRequest(messages: [
            .user("find swift"),
            .assistant("", toolCalls: [call]),
            .tool(callID: "call_7", name: "lookup", content: "found it"),
        ])
        let body = OpenAIWire.requestBody(model: "m", request: request, stream: false)
        let assistant = body["messages"]?[1]
        XCTAssertEqual(assistant?["tool_calls"]?[0]?["id"], .string("call_7"))
        XCTAssertEqual(assistant?["tool_calls"]?[0]?["function"]?["name"], .string("lookup"))
        XCTAssertEqual(
            assistant?["tool_calls"]?[0]?["function"]?["arguments"],
            .string(#"{"q":"swift"}"#)
        )
        let toolMessage = body["messages"]?[2]
        XCTAssertEqual(toolMessage?["role"], .string("tool"))
        XCTAssertEqual(toolMessage?["tool_call_id"], .string("call_7"))
        XCTAssertEqual(toolMessage?["content"], .string("found it"))
    }

    func testRequestBodyStreamingFlags() {
        let request = GenerationRequest(messages: [.user("x")])
        let body = OpenAIWire.requestBody(model: "m", request: request, stream: true)
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["stream_options"]?["include_usage"], .bool(true))
    }

    func testExtraBodyIsMerged() {
        let request = GenerationRequest(
            messages: [.user("x")],
            options: GenerationOptions(extraBody: ["repeat_penalty": .double(1.1)])
        )
        let body = OpenAIWire.requestBody(model: "m", request: request, stream: false)
        XCTAssertEqual(body["repeat_penalty"], .double(1.1))
    }

    func testMultimodalUserContent() {
        let request = GenerationRequest(messages: [
            .user([.text("what is this?"), .imageURL("https://example.com/x.png")])
        ])
        let body = OpenAIWire.requestBody(model: "m", request: request, stream: false)
        let content = body["messages"]?[0]?["content"]
        XCTAssertEqual(content?[0]?["type"], .string("text"))
        XCTAssertEqual(content?[1]?["type"], .string("image_url"))
        XCTAssertEqual(content?[1]?["image_url"]?["url"], .string("https://example.com/x.png"))
    }

    // MARK: Response decoding

    func testParseTextResponse() throws {
        let json = try JSONValue(parsing: #"""
        {"id": "chatcmpl-1", "choices": [{"message": {"role": "assistant", "content": "Hello!"},
         "finish_reason": "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 3}}
        """#)
        let response = try OpenAIWire.parseResponse(json)
        XCTAssertEqual(response.text, "Hello!")
        XCTAssertEqual(response.finishReason, .stop)
        XCTAssertEqual(response.usage, TokenUsage(inputTokens: 10, outputTokens: 3))
    }

    func testParseToolCallResponse() throws {
        let json = try JSONValue(parsing: #"""
        {"choices": [{"message": {"role": "assistant", "content": null,
          "tool_calls": [{"id": "call_abc", "type": "function",
            "function": {"name": "get_weather", "arguments": "{\"city\": \"Tokyo\"}"}}]},
          "finish_reason": "tool_calls"}]}
        """#)
        let response = try OpenAIWire.parseResponse(json)
        XCTAssertEqual(response.finishReason, .toolCalls)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls[0].id, "call_abc")
        XCTAssertEqual(response.toolCalls[0].name, "get_weather")
        XCTAssertEqual(response.toolCalls[0].arguments, ["city": "Tokyo"])
    }

    func testParseResponseWithoutChoicesThrows() {
        let json: JSONValue = ["object": "error"]
        XCTAssertThrowsError(try OpenAIWire.parseResponse(json))
    }

    // MARK: End-to-end via mock transport

    func testGenerateSendsAuthAndParsesResponse() async throws {
        let transport = MockTransport(json: #"""
        {"choices": [{"message": {"role": "assistant", "content": "42"}, "finish_reason": "stop"}]}
        """#)
        let provider = OpenAICompatibleProvider.openAI(model: "gpt-x", apiKey: "sk-test", transport: transport)
        let response = try await provider.generate(prompt: "meaning of life?")
        XCTAssertEqual(response.text, "42")

        let sent = await transport.sentRequests
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].headers["Authorization"], "Bearer sk-test")
        XCTAssertTrue(sent[0].url.absoluteString.hasSuffix("/chat/completions"))
        let body = try await transport.requestBody()
        XCTAssertEqual(body["model"], .string("gpt-x"))
    }

    func testGenerateThrowsOnHTTPError() async throws {
        let transport = MockTransport(
            json: #"{"error": {"message": "model not found"}}"#,
            statusCode: 404
        )
        let provider = OpenAICompatibleProvider.ollama(model: "nope", transport: transport)
        do {
            _ = try await provider.generate(prompt: "hi")
            XCTFail("expected an error")
        } catch let AgentKitError.httpError(statusCode, message) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(message, "model not found")
        }
    }

    // MARK: Streaming

    func testStreamTextDeltas() async throws {
        let sse = [
            "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n",
            "data: [DONE]\n\n",
        ]
        let transport = MockTransport(sseChunks: sse)
        let provider = OpenAICompatibleProvider.ollama(model: "m", transport: transport)

        var events: [StreamEvent] = []
        for try await event in provider.stream(GenerationRequest(messages: [.user("hi")])) {
            events.append(event)
        }

        XCTAssertEqual(events.first, .responseStarted(id: "c1"))
        XCTAssertTrue(events.contains(.textDelta("Hel")))
        XCTAssertTrue(events.contains(.textDelta("lo")))
        XCTAssertEqual(
            events.last,
            .finished(reason: .stop, usage: TokenUsage(inputTokens: 5, outputTokens: 2))
        )
    }

    func testStreamAssemblesToolCallsAcrossChunks() async throws {
        let sse = [
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"get_weather\",\"arguments\":\"\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"city\\\":\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"Oslo\\\"}\"}}]}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n",
        ]
        let transport = MockTransport(sseChunks: sse)
        let provider = OpenAICompatibleProvider.ollama(model: "m", transport: transport)

        var events: [StreamEvent] = []
        for try await event in provider.stream(GenerationRequest(messages: [.user("weather?")])) {
            events.append(event)
        }

        XCTAssertTrue(events.contains(.toolCallStarted(index: 0, id: "call_1", name: "get_weather")))
        let completed = events.compactMap { event -> ToolCall? in
            if case .toolCallCompleted(let call) = event { return call }
            return nil
        }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].name, "get_weather")
        XCTAssertEqual(completed[0].arguments, ["city": "Oslo"])
        XCTAssertEqual(events.last, .finished(reason: .toolCalls, usage: TokenUsage()))
    }

    func testStreamChunksSplitAtArbitraryByteBoundaries() async throws {
        // One SSE event delivered in three ragged chunks.
        let sse = [
            "data: {\"choices\":[{\"del",
            "ta\":{\"content\":\"chunked\"}}]}",
            "\n\ndata: [DONE]\n\n",
        ]
        let transport = MockTransport(sseChunks: sse)
        let provider = OpenAICompatibleProvider.ollama(model: "m", transport: transport)

        var text = ""
        for try await event in provider.stream(GenerationRequest(messages: [.user("x")])) {
            if case .textDelta(let delta) = event { text += delta }
        }
        XCTAssertEqual(text, "chunked")
    }
}
