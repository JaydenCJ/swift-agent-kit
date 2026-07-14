import Foundation
import XCTest
@testable import SwiftAgentKit

final class AgentLoopTests: XCTestCase {
    private func clockTool(reporting time: String = "12:34") -> Tool {
        Tool(
            name: "clock",
            description: "Current time",
            parameters: .object(properties: [:], required: [])
        ) { _ in .string(time) }
    }

    func testSingleShotAnswerWithoutTools() async throws {
        let provider = ScriptedProvider(responses: [.text("Just hello.")])
        let agent = Agent(provider: provider)
        let result = try await agent.run("say hello")
        XCTAssertEqual(result.text, "Just hello.")
        XCTAssertEqual(result.finishReason, .stop)
        XCTAssertEqual(result.steps.count, 1)
        XCTAssertEqual(result.messages.map(\.role), [.user, .assistant])
    }

    func testSystemPromptIsPrepended() async throws {
        let provider = ScriptedProvider(responses: [.text("ok")])
        let agent = Agent(provider: provider, systemPrompt: "be nice")
        _ = try await agent.run("hi")
        let first = provider.requests.first?.messages.first
        XCTAssertEqual(first?.role, .system)
        XCTAssertEqual(first?.text, "be nice")
    }

    func testToolCallLoop() async throws {
        let provider = ScriptedProvider(responses: [
            .toolCalls([ToolCall(id: "c1", name: "clock", arguments: .object([:]))],
                       usage: TokenUsage(inputTokens: 10, outputTokens: 5)),
            .text("The time is 12:34.", usage: TokenUsage(inputTokens: 20, outputTokens: 8)),
        ])
        let agent = Agent(provider: provider, tools: [clockTool()])
        let result = try await agent.run("what time is it?")

        XCTAssertEqual(result.text, "The time is 12:34.")
        XCTAssertEqual(result.steps.count, 2)
        XCTAssertEqual(result.steps[0].toolResults.count, 1)
        XCTAssertEqual(result.steps[0].toolResults[0].outputText, "12:34")
        XCTAssertFalse(result.steps[0].toolResults[0].isError)
        // Usage accumulates across both round-trips.
        XCTAssertEqual(result.usage, TokenUsage(inputTokens: 30, outputTokens: 13))

        // The second request must include the assistant tool call and the
        // tool result message.
        let secondRequest = provider.requests[1]
        let roles = secondRequest.messages.map(\.role)
        XCTAssertEqual(roles, [.user, .assistant, .tool])
        XCTAssertEqual(secondRequest.messages[2].toolCallID, "c1")
        XCTAssertEqual(secondRequest.messages[2].text, "12:34")
    }

    func testParallelToolCallsPreserveOrder() async throws {
        let slow = Tool(name: "slow", description: "", parameters: .any) { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return .string("slow-done")
        }
        let fast = Tool(name: "fast", description: "", parameters: .any) { _ in
            .string("fast-done")
        }
        let provider = ScriptedProvider(responses: [
            .toolCalls([
                ToolCall(id: "c1", name: "slow", arguments: .object([:])),
                ToolCall(id: "c2", name: "fast", arguments: .object([:])),
            ]),
            .text("done"),
        ])
        let agent = Agent(provider: provider, tools: [slow, fast])
        let result = try await agent.run("go")

        // Results come back in the model's call order even though the fast
        // tool finished first.
        XCTAssertEqual(result.steps[0].toolResults.map(\.callID), ["c1", "c2"])
        XCTAssertEqual(result.steps[0].toolResults.map(\.outputText), ["slow-done", "fast-done"])
    }

    func testUnknownToolProducesErrorResultAndLoopContinues() async throws {
        let provider = ScriptedProvider(responses: [
            .toolCalls([ToolCall(id: "c1", name: "ghost", arguments: .object([:]))]),
            .text("recovered"),
        ])
        let agent = Agent(provider: provider, tools: [clockTool()])
        let result = try await agent.run("use a tool I don't have")

        XCTAssertEqual(result.text, "recovered")
        let record = result.steps[0].toolResults[0]
        XCTAssertTrue(record.isError)
        XCTAssertTrue(record.outputText.contains("ghost"))
        // The error is fed back to the model as a tool message.
        XCTAssertEqual(provider.requests[1].messages.last?.isToolError, true)
    }

    func testThrowingToolIsReportedAsError() async throws {
        struct Boom: Error {}
        let exploding = Tool(name: "boom", description: "", parameters: .any) { _ in
            throw Boom()
        }
        let provider = ScriptedProvider(responses: [
            .toolCalls([ToolCall(id: "c1", name: "boom", arguments: .object([:]))]),
            .text("handled"),
        ])
        let agent = Agent(provider: provider, tools: [exploding])
        let result = try await agent.run("explode")
        XCTAssertTrue(result.steps[0].toolResults[0].isError)
        XCTAssertEqual(result.text, "handled")
    }

    func testMaxStepsStopsRunawayLoops() async throws {
        // A provider that always asks for another tool call.
        let responses = (0..<10).map { index in
            GenerationResponse.toolCalls([
                ToolCall(id: "c\(index)", name: "clock", arguments: .object([:]))
            ])
        }
        let provider = ScriptedProvider(responses: responses)
        let agent = Agent(provider: provider, tools: [clockTool()], maxSteps: 3)
        let result = try await agent.run("loop forever")

        XCTAssertEqual(result.steps.count, 3)
        XCTAssertEqual(result.finishReason, .other("max_steps"))
        XCTAssertEqual(result.text, "")
    }

    func testToolDefinitionsAreSentToProvider() async throws {
        let provider = ScriptedProvider(responses: [.text("ok")])
        let agent = Agent(provider: provider, tools: [clockTool()])
        _ = try await agent.run("hi")
        let sentTools = provider.requests[0].tools
        XCTAssertEqual(sentTools.map(\.name), ["clock"])
    }

    func testRunFromExistingConversation() async throws {
        let provider = ScriptedProvider(responses: [.text("continuing")])
        let agent = Agent(provider: provider)
        let history: [ChatMessage] = [
            .system("s"), .user("a"), .assistant("b"), .user("c"),
        ]
        let result = try await agent.run(messages: history)
        XCTAssertEqual(result.messages.count, 5)
        XCTAssertEqual(result.text, "continuing")
    }
}
