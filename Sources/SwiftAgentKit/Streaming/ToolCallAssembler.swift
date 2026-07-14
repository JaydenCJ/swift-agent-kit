import Foundation

/// Accumulates streamed tool-call fragments (OpenAI `delta.tool_calls` style)
/// into complete ``ToolCall`` values.
public struct ToolCallAssembler: Sendable {
    private struct Partial {
        var id: String = ""
        var name: String = ""
        var argumentsJSON: String = ""
    }

    private var partials: [Int: Partial] = [:]

    /// Creates an empty assembler.
    public init() {}

    /// `true` once at least one fragment has been received.
    public var hasCalls: Bool { !partials.isEmpty }

    /// Applies one streamed fragment for the tool call at `index`.
    ///
    /// - Returns: `.started` when the call's identity (id/name) first became
    ///   known, so callers can forward a ``StreamEvent/toolCallStarted(index:id:name:)``.
    @discardableResult
    public mutating func apply(
        index: Int,
        id: String?,
        name: String?,
        argumentsFragment: String?
    ) -> Bool {
        var partial = partials[index] ?? Partial()
        let wasAnonymous = partial.name.isEmpty
        if let id, !id.isEmpty { partial.id = id }
        if let name, !name.isEmpty { partial.name += name }
        if let argumentsFragment { partial.argumentsJSON += argumentsFragment }
        partials[index] = partial
        return wasAnonymous && !partial.name.isEmpty
    }

    /// The identity of the call at `index`, if known.
    public func identity(at index: Int) -> (id: String, name: String)? {
        guard let partial = partials[index], !partial.name.isEmpty else { return nil }
        return (partial.id, partial.name)
    }

    /// Finalizes all accumulated calls, ordered by stream index.
    ///
    /// Argument fragments are parsed as JSON; fragments that never became
    /// valid JSON are preserved as a raw string so nothing is lost.
    public func completedCalls() -> [ToolCall] {
        partials.keys.sorted().compactMap { index in
            guard let partial = partials[index], !partial.name.isEmpty else { return nil }
            let arguments: JSONValue
            if partial.argumentsJSON.isEmpty {
                arguments = .object([:])
            } else if let parsed = try? JSONValue(parsing: partial.argumentsJSON) {
                arguments = parsed
            } else {
                arguments = .string(partial.argumentsJSON)
            }
            let id = partial.id.isEmpty ? "call_\(index)" : partial.id
            return ToolCall(id: id, name: partial.name, arguments: arguments)
        }
    }
}
