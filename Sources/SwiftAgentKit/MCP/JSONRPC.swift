import Foundation

/// A JSON-RPC 2.0 request or notification identifier.
public enum JSONRPCID: Sendable, Equatable, Hashable, Codable {
    /// A numeric id.
    case number(Int)
    /// A string id.
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "JSON-RPC id must be a number or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        }
    }
}

/// A JSON-RPC 2.0 message (request, notification, response or error),
/// modeled as a single envelope for easy routing.
public struct JSONRPCMessage: Sendable, Equatable, Codable {
    /// The protocol version field; always `"2.0"`.
    public var jsonrpc: String
    /// The message id (absent for notifications).
    public var id: JSONRPCID?
    /// The method name (absent for responses).
    public var method: String?
    /// Request/notification parameters.
    public var params: JSONValue?
    /// The result payload of a successful response.
    public var result: JSONValue?
    /// The error object of a failed response.
    public var error: JSONRPCError?

    /// Creates a message envelope; prefer the static factories below.
    public init(
        id: JSONRPCID? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONRPCError? = nil
    ) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    /// A request expecting a response.
    public static func request(id: Int, method: String, params: JSONValue? = nil) -> JSONRPCMessage {
        JSONRPCMessage(id: .number(id), method: method, params: params)
    }

    /// A one-way notification.
    public static func notification(method: String, params: JSONValue? = nil) -> JSONRPCMessage {
        JSONRPCMessage(method: method, params: params)
    }

    /// A successful response.
    public static func response(id: JSONRPCID, result: JSONValue) -> JSONRPCMessage {
        JSONRPCMessage(id: id, result: result)
    }

    /// An error response.
    public static func errorResponse(id: JSONRPCID?, code: Int, message: String) -> JSONRPCMessage {
        JSONRPCMessage(id: id, error: JSONRPCError(code: code, message: message))
    }

    /// `true` for messages that are responses (have a result or error and no method).
    public var isResponse: Bool {
        method == nil && (result != nil || error != nil)
    }

    /// Serializes to a single line of JSON (MCP stdio framing is
    /// newline-delimited JSON).
    public func encodedLine() throws -> Data {
        let value = try JSONValue(encoding: self)
        var line = value.canonicalJSONString()
        line.append("\n")
        return Data(line.utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(JSONRPCError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// A JSON-RPC 2.0 error object.
public struct JSONRPCError: Sendable, Equatable, Codable, Error {
    /// The numeric error code.
    public var code: Int
    /// A short human-readable error description.
    public var message: String
    /// Optional structured error details.
    public var data: JSONValue?

    /// Creates an error object.
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// Standard JSON-RPC error code: invalid JSON was received.
    public static let parseError = -32700
    /// Standard JSON-RPC error code: the JSON is not a valid request.
    public static let invalidRequest = -32600
    /// Standard JSON-RPC error code: the method does not exist.
    public static let methodNotFound = -32601
    /// Standard JSON-RPC error code: invalid method parameters.
    public static let invalidParams = -32602
    /// Standard JSON-RPC error code: internal server error.
    public static let internalError = -32603
}
