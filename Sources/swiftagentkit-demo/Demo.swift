import Foundation
import SwiftAgentKit

/// The SwiftAgentKit demo: a local agent that can read a calendar via tool
/// calling.
///
/// Two modes:
///
///   swift run swiftagentkit-demo --offline "What's on my calendar tomorrow?"
///     Runs the full agent loop against a scripted provider — no server, no
///     network. Shows exactly what the loop does: model asks for a tool,
///     the tool runs locally, the model answers from the result.
///
///   swift run swiftagentkit-demo "What's on my calendar tomorrow?"
///     Runs against any OpenAI-compatible endpoint. Configure with:
///       SAK_BASE_URL  (default http://localhost:11434/v1 — Ollama)
///       SAK_MODEL     (default qwen3)
///       SAK_API_KEY   (optional)
@main
struct Demo {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let offline = arguments.contains("--offline")
        arguments.removeAll { $0 == "--offline" }
        let prompt = arguments.joined(separator: " ")

        guard !prompt.isEmpty else {
            print("""
            Usage:
              swift run swiftagentkit-demo [--offline] "<prompt>"

            Examples:
              swift run swiftagentkit-demo --offline "What's on my calendar tomorrow?"
              SAK_MODEL=qwen3 swift run swiftagentkit-demo "What's on my calendar tomorrow?"
            """)
            return
        }

        do {
            try await run(prompt: prompt, offline: offline)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    static func run(prompt: String, offline: Bool) async throws {
        // ─── The headline scenario: a calendar agent in ~30 lines ───────────

        // 1. A tool from a plain Codable struct. The JSON Schema for the
        //    model is inferred automatically.
        struct CalendarQuery: Codable { var day: String }
        let events = [
            "today": "09:00 Standup, 14:00 Design review",
            "tomorrow": "10:30 Dentist, 19:00 Dinner with Yuki",
        ]
        let calendar = try Tool.typed(
            name: "get_calendar_events",
            description: "Return the calendar events for a day ('today' or 'tomorrow')."
        ) { (query: CalendarQuery) in
            events[query.day.lowercased()] ?? "No events found for '\(query.day)'."
        }

        // 2. Pick a provider. Any ModelProvider works: an OpenAI-compatible
        //    local server (Ollama / llama.cpp / LM Studio), a cloud API, or
        //    — in this demo's offline mode — a scripted stand-in.
        let provider: any ModelProvider
        if offline {
            provider = ScriptedCalendarProvider()
        } else {
            let environment = ProcessInfo.processInfo.environment
            let baseURL = URL(string: environment["SAK_BASE_URL"] ?? "http://localhost:11434/v1")!
            provider = OpenAICompatibleProvider(
                baseURL: baseURL,
                model: environment["SAK_MODEL"] ?? "qwen3",
                apiKey: environment["SAK_API_KEY"]
            )
        }

        // 3. Run the agent loop.
        let agent = Agent(
            provider: provider,
            tools: [calendar],
            systemPrompt: "You are a concise calendar assistant. Use tools to check the calendar."
        )
        let result = try await agent.run(prompt)

        // ─────────────────────────────────────────────────────────────────────

        for (index, step) in result.steps.enumerated() {
            for record in step.toolResults {
                print("[step \(index + 1)] \(record.toolName)(\(record.arguments.canonicalJSONString())) -> \(record.outputText)")
            }
        }
        print()
        print(result.text)
    }
}

/// A deterministic provider for offline demos: first turn requests the
/// calendar tool, second turn answers from the tool result — the exact
/// message flow a real model produces, without a model.
struct ScriptedCalendarProvider: ModelProvider {
    let name = "scripted-demo"

    func generate(_ request: GenerationRequest) async throws -> GenerationResponse {
        let hasToolResult = request.messages.contains { $0.role == .tool }
        if !hasToolResult {
            let day = request.messages.last?.text.lowercased().contains("today") == true
                ? "today" : "tomorrow"
            return GenerationResponse(
                message: .assistant("", toolCalls: [
                    ToolCall(id: "call_1", name: "get_calendar_events", arguments: ["day": .string(day)])
                ]),
                finishReason: .toolCalls,
                usage: TokenUsage(inputTokens: 42, outputTokens: 12)
            )
        }
        let toolOutput = request.messages.last { $0.role == .tool }?.text ?? ""
        return GenerationResponse(
            message: .assistant("Here's your schedule: \(toolOutput)"),
            finishReason: .stop,
            usage: TokenUsage(inputTokens: 64, outputTokens: 18)
        )
    }
}
