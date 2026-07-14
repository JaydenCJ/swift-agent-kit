import Foundation

/// A decoded structured-output result.
public struct GeneratedObject<T: Sendable>: Sendable {
    /// The decoded value.
    public var object: T
    /// The raw JSON text the value was decoded from.
    public var rawText: String
    /// The underlying provider response.
    public var response: GenerationResponse

    /// Creates a result. Normally produced by `generateObject`.
    public init(object: T, rawText: String, response: GenerationResponse) {
        self.object = object
        self.rawText = rawText
        self.response = response
    }
}

/// Generates a typed value from a prompt: the schema is inferred from `T`
/// (or passed explicitly), sent to the provider as a JSON-Schema response
/// format, and the reply is decoded back into `T`.
///
/// ```swift
/// struct Recipe: Codable, Sendable {
///     var title: String
///     var minutes: Int
///     var ingredients: [String]
/// }
///
/// let result = try await generateObject(
///     Recipe.self,
///     provider: provider,
///     prompt: "A quick weeknight pasta recipe."
/// )
/// print(result.object.title)
/// ```
///
/// Models that wrap JSON in markdown fences or prose are handled: the first
/// complete JSON document in the reply is extracted before decoding.
///
/// - Parameter strict: Whether to request strict schema enforcement. The
///   default (`nil`) means *strict when possible*: strict mode is used
///   unless the schema contains an open object (a dictionary property such
///   as `[String: String]`, or a ``JSONValue``), which strict-mode providers
///   reject outright — those requests fall back to non-strict enforcement
///   plus the decode-time validation this function performs anyway. Pass
///   `true` or `false` to override.
public func generateObject<T: Decodable & Sendable>(
    _ type: T.Type = T.self,
    provider: any ModelProvider,
    prompt: String,
    system: String? = nil,
    schema: JSONSchema? = nil,
    schemaName: String = "output",
    strict: Bool? = nil,
    options: GenerationOptions = GenerationOptions()
) async throws -> GeneratedObject<T> {
    var messages: [ChatMessage] = []
    if let system {
        messages.append(.system(system))
    }
    messages.append(.user(prompt))
    return try await generateObject(
        type,
        provider: provider,
        messages: messages,
        schema: schema,
        schemaName: schemaName,
        strict: strict,
        options: options
    )
}

/// Generates a typed value from a full conversation. See
/// ``generateObject(_:provider:prompt:system:schema:schemaName:strict:options:)``.
public func generateObject<T: Decodable & Sendable>(
    _ type: T.Type = T.self,
    provider: any ModelProvider,
    messages: [ChatMessage],
    schema: JSONSchema? = nil,
    schemaName: String = "output",
    strict: Bool? = nil,
    options: GenerationOptions = GenerationOptions()
) async throws -> GeneratedObject<T> {
    let resolvedSchema: JSONSchema
    if let schema {
        resolvedSchema = schema
    } else {
        resolvedSchema = try JSONSchema.infer(from: T.self)
    }
    // Strict json_schema modes require closed objects everywhere; a schema
    // with an open (dictionary-like) object would draw a 400 from the
    // provider, so default those to non-strict.
    let resolvedStrict = strict ?? !resolvedSchema.containsOpenObject

    let request = GenerationRequest(
        messages: messages,
        responseFormat: .jsonSchema(name: schemaName, schema: resolvedSchema, strict: resolvedStrict),
        options: options
    )
    let response = try await provider.generate(request)
    let text = response.text
    guard let jsonText = LenientJSON.extractDocument(from: text) else {
        throw AgentKitError.objectDecodingFailed(
            underlying: "No JSON document found in the model response",
            rawText: text
        )
    }
    do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        let object = try decoder.decode(T.self, from: Data(jsonText.utf8))
        return GeneratedObject(object: object, rawText: jsonText, response: response)
    } catch {
        throw AgentKitError.objectDecodingFailed(underlying: "\(error)", rawText: jsonText)
    }
}

/// Extracts JSON documents from model output that may be wrapped in
/// markdown fences or surrounded by prose.
public enum LenientJSON {
    /// Returns the first complete JSON object or array in `text`, or `nil`.
    ///
    /// Handles, in order of preference:
    /// 1. the whole string being a JSON document,
    /// 2. a fenced code block (```json … ``` or ``` … ```),
    /// 3. the first balanced `{…}` or `[…]` anywhere in the text
    ///    (string-literal aware, so braces inside strings don't confuse it).
    public static func extractDocument(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let document = firstBalancedDocument(in: trimmed) {
                return document
            }
        }
        if let fenced = fencedBlock(in: text), let document = firstBalancedDocument(in: fenced) {
            return document
        }
        return firstBalancedDocument(in: text)
    }

    /// Returns the contents of the first fenced code block, if any.
    static func fencedBlock(in text: String) -> String? {
        guard let openFence = text.range(of: "```") else { return nil }
        var rest = text[openFence.upperBound...]
        // Skip an optional language tag on the fence line.
        if let newline = rest.firstIndex(of: "\n") {
            rest = rest[rest.index(after: newline)...]
        }
        guard let closeFence = rest.range(of: "```") else {
            return String(rest)
        }
        return String(rest[rest.startIndex..<closeFence.lowerBound])
    }

    /// Scans for the first `{` or `[` and returns the balanced document
    /// starting there, respecting string literals and escapes.
    static func firstBalancedDocument(in text: String) -> String? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{", "[":
                    depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
