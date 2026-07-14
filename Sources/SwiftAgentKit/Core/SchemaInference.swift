import Foundation

// MARK: - Public API

extension JSONSchema {
    /// Infers a JSON Schema from any `Decodable` type — no macros, no
    /// reflection of instances, no hand-written schemas.
    ///
    /// SwiftAgentKit runs the type's synthesized `init(from:)` against a
    /// *probing decoder* that hands back synthetic stand-in values while
    /// recording every property name and primitive type the initializer
    /// asks for.
    ///
    /// ```swift
    /// struct WeatherQuery: Codable {
    ///     var city: String
    ///     var days: Int?
    /// }
    /// let schema = try JSONSchema.infer(from: WeatherQuery.self)
    /// // {"type":"object","properties":{"city":{"type":"string"},
    /// //  "days":{"type":"integer"}},"required":["city"], ...}
    /// ```
    ///
    /// Supported out of the box: nested structs, arrays, optionals (become
    /// non-required properties), `String`-backed `CaseIterable` enums (become
    /// `enum` schemas), `Date` (ISO-8601 string), `URL`, `UUID`, `Data`
    /// (base64 string) and ``JSONValue`` (any value).
    ///
    /// > Note: Dictionary properties (e.g. `[String: String]`) infer as
    /// > *open* object schemas (`{"type":"object"}` with no fixed
    /// > properties), and ``JSONValue`` infers as `{}`. Strict
    /// > structured-output modes reject open schemas — `generateObject`
    /// > detects this via ``JSONSchema/containsOpenObject`` and falls back
    /// > to non-strict enforcement automatically; if you build a
    /// > ``ResponseFormat/jsonSchema(name:schema:strict:)`` yourself, pass
    /// > `strict: false` for such types (or supply an explicit closed
    /// > schema).
    ///
    /// - Throws: ``AgentKitError/schemaInference(_:)`` when the type cannot
    ///   be probed — most commonly a required enum property that is not
    ///   `CaseIterable` (conform it to `CaseIterable` to fix), or a recursive
    ///   type deeper than 32 levels.
    public static func infer<T: Decodable>(from type: T.Type) throws -> JSONSchema {
        let node = SchemaNode()
        do {
            _ = try SchemaProbe.probeValue(type, into: node, depth: 0)
        } catch let error as AgentKitError {
            throw error
        } catch {
            throw AgentKitError.schemaInference(
                "Could not infer a schema for \(T.self): \(error). "
                + "If the type contains a non-CaseIterable enum, conform it to CaseIterable, "
                + "or provide an explicit JSONSchema instead."
            )
        }
        return node.schema()
    }
}

// MARK: - Recording model

/// Mutable schema node built up while probing. Probing is synchronous and
/// single-threaded, so plain classes are safe here.
final class SchemaNode {
    enum Kind {
        case unknown
        case anyValue
        case boolean
        case integer
        case number
        case string
        case array
        case object
    }

    var kind: Kind = .unknown
    var format: String?
    var enumValues: [String]?
    /// Object properties in declaration (probe) order.
    var properties: [(name: String, node: SchemaNode)] = []
    var required: [String] = []
    var element: SchemaNode?

    func childNode(for key: String) -> SchemaNode {
        if let existing = properties.first(where: { $0.name == key }) {
            return existing.node
        }
        let node = SchemaNode()
        properties.append((key, node))
        return node
    }

    func markRequired(_ key: String) {
        if !required.contains(key) {
            required.append(key)
        }
    }

    func schema() -> JSONSchema {
        switch kind {
        case .unknown, .anyValue:
            return .any
        case .boolean:
            return .boolean()
        case .integer:
            return .integer()
        case .number:
            return .number()
        case .string:
            return .string(enumValues: enumValues, format: format)
        case .array:
            return .array(of: element?.schema() ?? .any)
        case .object:
            // A keyed container that never decoded a fixed key is a
            // dictionary-like type: emit an open object schema.
            if properties.isEmpty {
                return JSONSchema(value: ["type": "object"])
            }
            var propertySchemas: [String: JSONSchema] = [:]
            for (name, node) in properties {
                propertySchemas[name] = node.schema()
            }
            return .object(properties: propertySchemas, required: required.sorted())
        }
    }
}

// MARK: - Probe entry point

enum SchemaProbe {
    static let maxDepth = 32

    /// Constructs a synthetic stand-in instance of `type`, recording its
    /// structure into `node` along the way.
    static func probeValue<T: Decodable>(_ type: T.Type, into node: SchemaNode, depth: Int) throws -> T {
        if depth > maxDepth {
            throw AgentKitError.schemaInference(
                "Schema inference exceeded the maximum depth of \(maxDepth); is \(T.self) recursive?"
            )
        }

        // Foundation types with special JSON representations.
        if type == JSONValue.self {
            node.kind = .anyValue
            return JSONValue.null as! T
        }
        if type == Date.self {
            node.kind = .string
            node.format = "date-time"
            return Date(timeIntervalSince1970: 0) as! T
        }
        if type == URL.self {
            node.kind = .string
            node.format = "uri"
            return URL(string: "https://example.invalid/")! as! T
        }
        if type == UUID.self {
            node.kind = .string
            node.format = "uuid"
            return UUID() as! T
        }
        if type == Data.self {
            node.kind = .string
            return Data() as! T
        }
        if type == Decimal.self {
            node.kind = .number
            return Decimal(0) as! T
        }

        // String-backed CaseIterable enums surface their cases as an
        // `enum` constraint.
        if let enumType = type as? any (RawRepresentable & CaseIterable & Decodable).Type {
            if let probed = probeStringEnum(enumType) {
                node.kind = .string
                node.enumValues = probed.rawValues
                return probed.instance as! T
            }
        }

        return try T(from: ProbingDecoder(node: node, depth: depth))
    }

    private static func probeStringEnum(
        _ type: any (RawRepresentable & CaseIterable & Decodable).Type
    ) -> (rawValues: [String], instance: Any)? {
        func open<E: RawRepresentable & CaseIterable & Decodable>(
            _ enumType: E.Type
        ) -> (rawValues: [String], instance: Any)? {
            let cases = Array(E.allCases)
            guard let first = cases.first else { return nil }
            var rawValues: [String] = []
            for enumCase in cases {
                guard let rawString = enumCase.rawValue as? String else { return nil }
                rawValues.append(rawString)
            }
            return (rawValues, first)
        }
        return open(type)
    }
}

// MARK: - Probing decoder

private struct ProbingDecoder: Decoder {
    let node: SchemaNode
    let depth: Int

    var codingPath: [CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        node.kind = .object
        return KeyedDecodingContainer(ProbingKeyedContainer<Key>(node: node, depth: depth))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        node.kind = .array
        let element = SchemaNode()
        node.element = element
        return ProbingUnkeyedContainer(elementNode: element, depth: depth)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        ProbingSingleValueContainer(node: node, depth: depth)
    }
}

// MARK: - Keyed container

private struct ProbingKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let node: SchemaNode
    let depth: Int

    var codingPath: [CodingKey] { [] }
    var allKeys: [Key] { [] }

    func contains(_ key: Key) -> Bool { true }

    func decodeNil(forKey key: Key) throws -> Bool { false }

    // Required properties (synthesized code calls `decode` for non-optionals).

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        record(.boolean, key, required: true); return false
    }
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        record(.string, key, required: true); return ""
    }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        record(.number, key, required: true); return 0
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        record(.number, key, required: true); return 0
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        record(.integer, key, required: true); return 0
    }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        record(.integer, key, required: true); return 0
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let child = node.childNode(for: key.stringValue)
        node.markRequired(key.stringValue)
        return try SchemaProbe.probeValue(type, into: child, depth: depth + 1)
    }

    // Optional properties (synthesized code calls `decodeIfPresent`).

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
        record(.boolean, key, required: false); return false
    }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
        record(.string, key, required: false); return ""
    }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
        record(.number, key, required: false); return 0
    }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        record(.number, key, required: false); return 0
    }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
        record(.integer, key, required: false); return 0
    }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
        record(.integer, key, required: false); return 0
    }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        let child = node.childNode(for: key.stringValue)
        // Optional properties tolerate probe failures: the partially
        // recorded child schema is still useful, and returning nil is valid.
        return try? SchemaProbe.probeValue(type, into: child, depth: depth + 1)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let child = node.childNode(for: key.stringValue)
        node.markRequired(key.stringValue)
        child.kind = .object
        return KeyedDecodingContainer(ProbingKeyedContainer<NestedKey>(node: child, depth: depth + 1))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let child = node.childNode(for: key.stringValue)
        node.markRequired(key.stringValue)
        child.kind = .array
        let element = SchemaNode()
        child.element = element
        return ProbingUnkeyedContainer(elementNode: element, depth: depth + 1)
    }

    func superDecoder() throws -> Decoder {
        ProbingDecoder(node: node, depth: depth + 1)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        ProbingDecoder(node: node.childNode(for: key.stringValue), depth: depth + 1)
    }

    private func record(_ kind: SchemaNode.Kind, _ key: Key, required: Bool) {
        let child = node.childNode(for: key.stringValue)
        if child.kind == .unknown { child.kind = kind }
        if required { node.markRequired(key.stringValue) }
    }
}

// MARK: - Unkeyed container

private final class ProbingUnkeyedContainer: UnkeyedDecodingContainer {
    let elementNode: SchemaNode
    let depth: Int
    private(set) var currentIndex: Int = 0

    init(elementNode: SchemaNode, depth: Int) {
        self.elementNode = elementNode
        self.depth = depth
    }

    var codingPath: [CodingKey] { [] }
    var count: Int? { 1 }
    var isAtEnd: Bool { currentIndex >= 1 }

    func decodeNil() throws -> Bool { false }

    func decode(_ type: Bool.Type) throws -> Bool { record(.boolean); return false }
    func decode(_ type: String.Type) throws -> String { record(.string); return "" }
    func decode(_ type: Double.Type) throws -> Double { record(.number); return 0 }
    func decode(_ type: Float.Type) throws -> Float { record(.number); return 0 }
    func decode(_ type: Int.Type) throws -> Int { record(.integer); return 0 }
    func decode(_ type: Int8.Type) throws -> Int8 { record(.integer); return 0 }
    func decode(_ type: Int16.Type) throws -> Int16 { record(.integer); return 0 }
    func decode(_ type: Int32.Type) throws -> Int32 { record(.integer); return 0 }
    func decode(_ type: Int64.Type) throws -> Int64 { record(.integer); return 0 }
    func decode(_ type: UInt.Type) throws -> UInt { record(.integer); return 0 }
    func decode(_ type: UInt8.Type) throws -> UInt8 { record(.integer); return 0 }
    func decode(_ type: UInt16.Type) throws -> UInt16 { record(.integer); return 0 }
    func decode(_ type: UInt32.Type) throws -> UInt32 { record(.integer); return 0 }
    func decode(_ type: UInt64.Type) throws -> UInt64 { record(.integer); return 0 }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        currentIndex += 1
        return try SchemaProbe.probeValue(type, into: elementNode, depth: depth + 1)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        currentIndex += 1
        elementNode.kind = .object
        return KeyedDecodingContainer(ProbingKeyedContainer<NestedKey>(node: elementNode, depth: depth + 1))
    }

    func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        currentIndex += 1
        elementNode.kind = .array
        let element = SchemaNode()
        elementNode.element = element
        return ProbingUnkeyedContainer(elementNode: element, depth: depth + 1)
    }

    func superDecoder() throws -> Decoder {
        currentIndex += 1
        return ProbingDecoder(node: elementNode, depth: depth + 1)
    }

    private func record(_ kind: SchemaNode.Kind) {
        currentIndex += 1
        if elementNode.kind == .unknown { elementNode.kind = kind }
    }
}

// MARK: - Single-value container

private struct ProbingSingleValueContainer: SingleValueDecodingContainer {
    let node: SchemaNode
    let depth: Int

    var codingPath: [CodingKey] { [] }

    func decodeNil() -> Bool { false }

    func decode(_ type: Bool.Type) throws -> Bool { record(.boolean); return false }
    func decode(_ type: String.Type) throws -> String { record(.string); return "" }
    func decode(_ type: Double.Type) throws -> Double { record(.number); return 0 }
    func decode(_ type: Float.Type) throws -> Float { record(.number); return 0 }
    func decode(_ type: Int.Type) throws -> Int { record(.integer); return 0 }
    func decode(_ type: Int8.Type) throws -> Int8 { record(.integer); return 0 }
    func decode(_ type: Int16.Type) throws -> Int16 { record(.integer); return 0 }
    func decode(_ type: Int32.Type) throws -> Int32 { record(.integer); return 0 }
    func decode(_ type: Int64.Type) throws -> Int64 { record(.integer); return 0 }
    func decode(_ type: UInt.Type) throws -> UInt { record(.integer); return 0 }
    func decode(_ type: UInt8.Type) throws -> UInt8 { record(.integer); return 0 }
    func decode(_ type: UInt16.Type) throws -> UInt16 { record(.integer); return 0 }
    func decode(_ type: UInt32.Type) throws -> UInt32 { record(.integer); return 0 }
    func decode(_ type: UInt64.Type) throws -> UInt64 { record(.integer); return 0 }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try SchemaProbe.probeValue(type, into: node, depth: depth + 1)
    }

    private func record(_ kind: SchemaNode.Kind) {
        if node.kind == .unknown { node.kind = kind }
    }
}
