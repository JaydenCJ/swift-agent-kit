import Foundation

/// A JSON Schema document, used to describe tool parameters and
/// structured-output shapes.
///
/// `JSONSchema` is a thin, ergonomic wrapper over a ``JSONValue`` tree, so it
/// can represent any schema a provider or MCP server hands back, while the
/// static builders (`.object`, `.string`, `.array`, …) cover the subset that
/// LLM tool calling actually uses.
public struct JSONSchema: Sendable, Equatable, Codable {
    /// The underlying schema document.
    public var value: JSONValue

    /// Wraps a raw ``JSONValue`` schema document.
    public init(value: JSONValue) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        self.value = try JSONValue(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }

    /// The `"type"` keyword of the schema, if present.
    public var type: String? { value["type"]?.stringValue }

    /// The `"properties"` map for object schemas.
    public var properties: [String: JSONSchema]? {
        guard let object = value["properties"]?.objectValue else { return nil }
        return object.mapValues { JSONSchema(value: $0) }
    }

    /// The `"required"` property names for object schemas.
    public var required: [String]? {
        value["required"]?.arrayValue?.compactMap { $0.stringValue }
    }

    /// The `"items"` schema for array schemas.
    public var items: JSONSchema? {
        value["items"].map { JSONSchema(value: $0) }
    }

    /// Serializes the schema to a deterministic JSON string.
    public func canonicalJSONString() -> String {
        value.canonicalJSONString()
    }

    /// Whether this schema (or any schema nested in it) is an *open* one —
    /// an object with no fixed `properties` (as inference produces for
    /// dictionary types like `[String: String]`) or a fully unconstrained
    /// `{}` (as inference produces for ``JSONValue``).
    ///
    /// Strict structured-output modes (OpenAI `json_schema` with
    /// `strict: true`, Anthropic structured outputs) require
    /// `additionalProperties: false` and a closed shape on every object, so
    /// they reject open schemas. ``generateObject(_:provider:prompt:system:schema:schemaName:strict:options:)``
    /// checks this to decide its default strictness.
    public var containsOpenObject: Bool {
        Self.containsOpenObject(value)
    }

    private static func containsOpenObject(_ value: JSONValue) -> Bool {
        guard let object = value.objectValue else { return false }
        if object.isEmpty {
            return true // `{}` accepts anything.
        }
        if object["type"]?.stringValue == "object", object["properties"] == nil {
            return true // dictionary-like: keys are not enumerable.
        }
        if let properties = object["properties"]?.objectValue {
            for (_, property) in properties where containsOpenObject(property) {
                return true
            }
        }
        if let items = object["items"], containsOpenObject(items) {
            return true
        }
        for combinator in ["anyOf", "oneOf", "allOf"] {
            if let alternatives = object[combinator]?.arrayValue {
                for alternative in alternatives where containsOpenObject(alternative) {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Builders

extension JSONSchema {
    /// An unconstrained schema (`{}`) that accepts any JSON value.
    public static var any: JSONSchema { JSONSchema(value: .object([:])) }

    /// A `null` schema.
    public static var null: JSONSchema { JSONSchema(value: ["type": "null"]) }

    /// A boolean schema.
    public static func boolean(description: String? = nil) -> JSONSchema {
        make(type: "boolean", description: description)
    }

    /// An integer schema.
    public static func integer(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONSchema {
        var schema = make(type: "integer", description: description)
        if let minimum { schema.set("minimum", to: .int(minimum)) }
        if let maximum { schema.set("maximum", to: .int(maximum)) }
        return schema
    }

    /// A number (floating point) schema.
    public static func number(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONSchema {
        var schema = make(type: "number", description: description)
        if let minimum { schema.set("minimum", to: .double(minimum)) }
        if let maximum { schema.set("maximum", to: .double(maximum)) }
        return schema
    }

    /// A string schema, optionally constrained to a fixed set of values.
    public static func string(
        description: String? = nil,
        enumValues: [String]? = nil,
        format: String? = nil,
        pattern: String? = nil
    ) -> JSONSchema {
        var schema = make(type: "string", description: description)
        if let enumValues {
            schema.set("enum", to: .array(enumValues.map { .string($0) }))
        }
        if let format { schema.set("format", to: .string(format)) }
        if let pattern { schema.set("pattern", to: .string(pattern)) }
        return schema
    }

    /// An array schema with a fixed element schema.
    public static func array(
        of items: JSONSchema,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> JSONSchema {
        var schema = make(type: "array", description: description)
        schema.set("items", to: items.value)
        if let minItems { schema.set("minItems", to: .int(minItems)) }
        if let maxItems { schema.set("maxItems", to: .int(maxItems)) }
        return schema
    }

    /// An object schema.
    ///
    /// - Parameters:
    ///   - properties: Property name to schema map.
    ///   - required: Required property names. Pass `nil` to require *all*
    ///     properties (the common case for tool parameters).
    ///   - additionalProperties: Whether extra keys are allowed. Defaults to
    ///     `false`, which strict tool-calling modes require.
    public static func object(
        properties: [String: JSONSchema],
        required: [String]? = nil,
        description: String? = nil,
        additionalProperties: Bool = false
    ) -> JSONSchema {
        var schema = make(type: "object", description: description)
        var propertyValues: [String: JSONValue] = [:]
        for (name, property) in properties {
            propertyValues[name] = property.value
        }
        schema.set("properties", to: .object(propertyValues))
        let requiredNames = required ?? properties.keys.sorted()
        schema.set("required", to: .array(requiredNames.map { .string($0) }))
        schema.set("additionalProperties", to: .bool(additionalProperties))
        return schema
    }

    /// A schema matching any of the given alternatives (`anyOf`).
    public static func anyOf(_ schemas: [JSONSchema], description: String? = nil) -> JSONSchema {
        var value: [String: JSONValue] = ["anyOf": .array(schemas.map { $0.value })]
        if let description { value["description"] = .string(description) }
        return JSONSchema(value: .object(value))
    }

    /// Returns a copy of this schema with a `"description"` set.
    public func described(_ description: String) -> JSONSchema {
        var copy = self
        copy.set("description", to: .string(description))
        return copy
    }

    private static func make(type: String, description: String?) -> JSONSchema {
        var value: [String: JSONValue] = ["type": .string(type)]
        if let description { value["description"] = .string(description) }
        return JSONSchema(value: .object(value))
    }

    private mutating func set(_ key: String, to newValue: JSONValue) {
        guard case .object(var object) = value else { return }
        object[key] = newValue
        value = .object(object)
    }
}
