import Foundation

/// The tool-calling loop: prompt → model → execute tools → feed results
/// back → repeat, until the model answers in plain text or the step budget
/// runs out.
///
/// ```swift
/// let agent = Agent(
///     provider: OpenAICompatibleProvider.ollama(model: "qwen3"),
///     tools: [calendarTool, clockTool],
///     systemPrompt: "You are a helpful calendar assistant."
/// )
/// let result = try await agent.run("What's on my calendar tomorrow?")
/// print(result.text)
/// ```
public struct Agent: Sendable {
    /// The backend that generates each model turn.
    public var provider: any ModelProvider
    /// Tools the model may call, exposed by name in every request.
    public var tools: [Tool]
    /// Optional system prompt prepended to the conversation.
    public var systemPrompt: String?
    /// Maximum number of model round-trips before the loop stops.
    public var maxSteps: Int
    /// Generation options passed through to the provider on every step.
    public var options: GenerationOptions
    /// When `true` (default), tool calls within one step run concurrently.
    public var parallelToolExecution: Bool

    /// Creates an agent. `maxSteps` is clamped to at least 1.
    public init(
        provider: any ModelProvider,
        tools: [Tool] = [],
        systemPrompt: String? = nil,
        maxSteps: Int = 8,
        options: GenerationOptions = GenerationOptions(),
        parallelToolExecution: Bool = true
    ) {
        self.provider = provider
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.maxSteps = max(1, maxSteps)
        self.options = options
        self.parallelToolExecution = parallelToolExecution
    }

    /// Runs the agent on a single user prompt.
    public func run(_ prompt: String) async throws -> AgentResult {
        var messages: [ChatMessage] = []
        if let systemPrompt {
            messages.append(.system(systemPrompt))
        }
        messages.append(.user(prompt))
        return try await run(messages: messages)
    }

    /// Runs the agent on an existing conversation.
    public func run(messages initialMessages: [ChatMessage]) async throws -> AgentResult {
        var messages = initialMessages
        var steps: [AgentStep] = []
        var usage = TokenUsage()
        var finishReason: FinishReason = .other("max_steps")
        var finalText = ""

        for _ in 0..<maxSteps {
            let request = GenerationRequest(
                messages: messages,
                tools: tools.map { $0.definition },
                options: options
            )
            let response = try await provider.generate(request)
            usage += response.usage
            messages.append(response.message)

            guard !response.toolCalls.isEmpty else {
                steps.append(AgentStep(response: response, toolResults: []))
                finishReason = response.finishReason
                finalText = response.text
                return AgentResult(
                    text: finalText,
                    messages: messages,
                    steps: steps,
                    finishReason: finishReason,
                    usage: usage
                )
            }

            let records = await executeToolCalls(response.toolCalls)
            steps.append(AgentStep(response: response, toolResults: records))
            for record in records {
                messages.append(.tool(
                    callID: record.callID,
                    name: record.toolName,
                    content: record.outputText,
                    isError: record.isError
                ))
            }
        }

        return AgentResult(
            text: finalText,
            messages: messages,
            steps: steps,
            finishReason: finishReason,
            usage: usage
        )
    }

    /// Executes all tool calls of one step, preserving call order in the
    /// returned records.
    private func executeToolCalls(_ calls: [ToolCall]) async -> [ToolExecutionRecord] {
        if parallelToolExecution && calls.count > 1 {
            return await withTaskGroup(of: (Int, ToolExecutionRecord).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask {
                        (index, await self.executeSingle(call))
                    }
                }
                var indexed: [(Int, ToolExecutionRecord)] = []
                for await entry in group {
                    indexed.append(entry)
                }
                return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }
        var records: [ToolExecutionRecord] = []
        for call in calls {
            records.append(await executeSingle(call))
        }
        return records
    }

    private func executeSingle(_ call: ToolCall) async -> ToolExecutionRecord {
        guard let tool = tools.first(where: { $0.name == call.name }) else {
            return ToolExecutionRecord(
                callID: call.id,
                toolName: call.name,
                arguments: call.arguments,
                outputText: "Error: \(AgentKitError.toolNotFound(call.name))",
                isError: true
            )
        }
        do {
            let output = try await tool.execute(call.arguments)
            return ToolExecutionRecord(
                callID: call.id,
                toolName: call.name,
                arguments: call.arguments,
                outputText: Tool.renderOutput(output),
                isError: false
            )
        } catch {
            return ToolExecutionRecord(
                callID: call.id,
                toolName: call.name,
                arguments: call.arguments,
                outputText: "Error: \(error)",
                isError: true
            )
        }
    }
}

/// One model round-trip plus the tool executions it triggered.
public struct AgentStep: Sendable {
    /// The provider response for this round-trip.
    public var response: GenerationResponse
    /// The results of the tool calls requested in ``response`` (empty for
    /// a plain-text turn), in the model's call order.
    public var toolResults: [ToolExecutionRecord]

    /// Creates a step record.
    public init(response: GenerationResponse, toolResults: [ToolExecutionRecord]) {
        self.response = response
        self.toolResults = toolResults
    }
}

/// The outcome of executing a single tool call.
public struct ToolExecutionRecord: Sendable, Equatable {
    /// The provider-assigned tool-call id this record answers.
    public var callID: String
    /// The name of the tool that was (or failed to be) executed.
    public var toolName: String
    /// The JSON arguments the model supplied.
    public var arguments: JSONValue
    /// The rendered tool output, or an error description if ``isError``.
    public var outputText: String
    /// `true` when the tool threw or could not be found.
    public var isError: Bool

    /// Creates an execution record.
    public init(
        callID: String,
        toolName: String,
        arguments: JSONValue,
        outputText: String,
        isError: Bool
    ) {
        self.callID = callID
        self.toolName = toolName
        self.arguments = arguments
        self.outputText = outputText
        self.isError = isError
    }
}

/// The final result of an agent run.
public struct AgentResult: Sendable {
    /// The model's final text answer ("" if the step budget ran out
    /// mid-tool-use).
    public var text: String
    /// The full transcript, including tool calls and results.
    public var messages: [ChatMessage]
    /// Every model round-trip taken.
    public var steps: [AgentStep]
    /// Why the run ended. `.other("max_steps")` means the budget ran out.
    public var finishReason: FinishReason
    /// Token usage accumulated across all steps.
    public var usage: TokenUsage

    /// Creates a result. Normally produced by ``Agent/run(_:)``.
    public init(
        text: String,
        messages: [ChatMessage],
        steps: [AgentStep],
        finishReason: FinishReason,
        usage: TokenUsage
    ) {
        self.text = text
        self.messages = messages
        self.steps = steps
        self.finishReason = finishReason
        self.usage = usage
    }
}
