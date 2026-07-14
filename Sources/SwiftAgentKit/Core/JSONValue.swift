import Foundation

/// A type-safe, `Sendable` representation of any JSON value.
///
/// `JSONValue` is the lingua franca of SwiftAgentKit: tool-call arguments,
/// JSON Schemas, provider wire payloads and MCP messages all flow through it.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not a valid JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - Accessors

extension JSONValue {
    /// The wrapped string, if this is `.string`.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The wrapped boolean, if this is `.bool`.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The wrapped integer. Also converts an exact-integral `.double`.
    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.truncatingRemainder(dividingBy: 1) == 0,
                  value >= Double(Int.min), value <= Double(Int.max) else { return nil }
            return Int(value)
        default: return nil
        }
    }

    /// The numeric value as `Double`, if this is `.int` or `.double`.
    public var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// The wrapped array, if this is `.array`.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The wrapped object, if this is `.object`.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// `true` if this is `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Member lookup for `.object` values.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    /// Element lookup for `.array` values. Out-of-bounds indices return `nil`.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Conversion

extension JSONValue {
    /// Decodes a `JSONValue` from raw JSON data.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses a `JSONValue` from a JSON string.
    public init(parsing jsonString: String) throws {
        try self.init(data: Data(jsonString.utf8))
    }

    /// Converts any `Encodable` value into a `JSONValue` tree.
    ///
    /// `Date` values are encoded as ISO-8601 strings and `Data` as base64,
    /// mirroring what ``JSONValue/decode(as:)`` expects.
    public init(encoding value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        let data = try encoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Serializes this value to JSON `Data`.
    public func jsonData() throws -> Data {
        Data(canonicalJSONString().utf8)
    }

    /// Decodes this JSON value into a concrete `Decodable` type.
    ///
    /// `Date` values are decoded from ISO-8601 strings and `Data` from base64.
    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(T.self, from: try jsonData())
    }
}

// MARK: - Canonical serialization

extension JSONValue {
    /// Serializes this value to a canonical JSON string: object keys are
    /// sorted, output is deterministic across runs and platforms.
    ///
    /// Deterministic serialization matters for provider prompt caching
    /// (byte-identical prefixes) and for snapshot tests.
    public func canonicalJSONString() -> String {
        var output = ""
        writeCanonical(into: &output)
        return output
    }

    private func writeCanonical(into output: inout String) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .double(let value):
            if value.isFinite {
                output += String(value)
            } else {
                output += "null"
            }
        case .string(let value):
            JSONValue.writeEscapedString(value, into: &output)
        case .array(let values):
            output += "["
            for (index, element) in values.enumerated() {
                if index > 0 { output += "," }
                element.writeCanonical(into: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                JSONValue.writeEscapedString(key, into: &output)
                output += ":"
                object[key]?.writeCanonical(into: &output)
            }
            output += "}"
        }
    }

    private static func writeEscapedString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}
