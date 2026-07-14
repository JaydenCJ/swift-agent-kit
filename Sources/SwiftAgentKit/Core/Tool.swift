import Foundation

/// A callable tool: schema plus implementation.
///
/// Build one directly with a closure over ``JSONValue`` arguments, or use
/// ``Tool/typed(name:description:parameters:run:)`` to get typed inputs and
/// an auto-inferred parameter schema from a plain `Codable` struct.
public struct Tool: Sendable {
    /// The tool name the model calls it by.
    public var name: String
    /// What the tool does, written for the model.
    public var description: String
    /// JSON Schema of the tool's arguments.
    public var parameters: JSONSchema
    /// Executes the tool. Receives parsed JSON arguments, returns a JSON result.
    public var execute: @Sendable (JSONValue) async throws -> JSONValue

    /// Creates a tool from an untyped closure over ``JSONValue`` arguments.
    public init(
        name: String,
        description: String,
        parameters: JSONSchema,
        execute: @escaping @Sendable (JSONValue) async throws -> JSONValue
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.execute = execute
    }

    /// The schema-only view of this tool, for provider requests.
    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: parameters)
    }

    /// Creates a tool with a typed input and output.
    ///
    /// The parameter schema is inferred from `Input` via
    /// ``JSONSchema/infer(from:)`` unless one is passed explicitly. The
    /// model's JSON arguments are decoded into `Input` before your closure
    /// runs, and the `Output` is encoded back to JSON for the model.
    ///
    /// ```swift
    /// struct WeatherQuery: Codable { var city: String }
    ///
    /// let weather = try Tool.typed(
    ///     name: "get_weather",
    ///     description: "Look up the current weather for a city."
    /// ) { (query: WeatherQuery) in
    ///     "Sunny and 22°C in \(query.city)"
    /// }
    /// ```
    ///
    /// - Throws: ``AgentKitError/schemaInference(_:)`` if no explicit schema
    ///   is given and `Input` cannot be inferred.
    public static func typed<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        name: String,
        description: String,
        parameters: JSONSchema? = nil,
        run: @escaping @Sendable (Input) async throws -> Output
    ) throws -> Tool {
        let schema: JSONSchema
        if let parameters {
            schema = parameters
        } else {
            schema = try JSONSchema.infer(from: Input.self)
        }
        return Tool(name: name, description: description, parameters: schema) { arguments in
            let input: Input
            do {
                input = try arguments.decode(as: Input.self)
            } catch {
                throw AgentKitError.invalidToolArguments(tool: name, underlying: "\(error)")
            }
            let output = try await run(input)
            if let text = output as? String {
                return .string(text)
            }
            return try JSONValue(encoding: output)
        }
    }

    /// Renders a tool output as the text content of a tool-result message.
    /// Plain strings pass through; everything else becomes canonical JSON.
    public static func renderOutput(_ output: JSONValue) -> String {
        if case .string(let text) = output { return text }
        return output.canonicalJSONString()
    }
}
