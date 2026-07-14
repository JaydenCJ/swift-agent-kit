import Foundation

/// Information about a connected MCP server.
public struct MCPServerInfo: Sendable, Equatable {
    /// The server's self-reported name.
    public var name: String
    /// The server's self-reported version.
    public var version: String
    /// The MCP protocol revision negotiated during `initialize`.
    public var protocolVersion: String
    /// The raw capabilities object from the handshake.
    public var capabilities: JSONValue

    /// Creates a server-info record.
    public init(name: String, version: String, protocolVersion: String, capabilities: JSONValue) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

/// A tool exposed by an MCP server.
public struct MCPToolInfo: Sendable, Equatable {
    /// The tool name as listed by the server.
    public var name: String
    /// The server's description of the tool, if any.
    public var description: String?
    /// The tool's input JSON Schema, verbatim from the server.
    public var inputSchema: JSONValue

    /// Creates a tool-info record.
    public init(name: String, description: String?, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// A content block from an MCP tool result.
public enum MCPContent: Sendable, Equatable {
    /// A text block.
    case text(String)
    /// An image block (base64 payload plus MIME type).
    case image(base64: String, mimeType: String)
    /// Any block type this client does not model explicitly.
    case other(JSONValue)
}

/// The result of calling an MCP tool.
public struct MCPToolResult: Sendable, Equatable {
    /// The result's content blocks, in server order.
    public var content: [MCPContent]
    /// `true` when the server flagged the call as failed.
    public var isError: Bool

    /// Creates a tool result.
    public init(content: [MCPContent], isError: Bool) {
        self.content = content
        self.isError = isError
    }

    /// All text blocks joined with newlines.
    public var text: String {
        content.compactMap { block in
            if case .text(let value) = block { return value }
            return nil
        }.joined(separator: "\n")
    }
}

/// A Model Context Protocol client.
///
/// Speaks JSON-RPC 2.0 over any ``MCPTransport``: performs the
/// `initialize` handshake, lists tools, calls tools, matches responses to
/// requests by ID (out-of-order safe), and answers server `ping`s.
///
/// ```swift
/// let client = MCPClient(transport: StdioTransport(
///     executable: "/usr/bin/npx",
///     arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
/// ))
/// try await client.connect()
/// let tools = try await client.tools()   // ready for Agent(tools:)
/// ```
public actor MCPClient {
    /// The MCP protocol revision this client requests.
    public static let protocolVersion = "2025-06-18"

    private let transport: any MCPTransport
    private let clientName: String
    private let clientVersion: String

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private var connected = false

    /// Populated after ``connect()``.
    public private(set) var serverInfo: MCPServerInfo?

    /// Creates a client over `transport`; call ``connect()`` before use.
    public init(
        transport: any MCPTransport,
        clientName: String = "SwiftAgentKit",
        clientVersion: String = "0.1.0"
    ) {
        self.transport = transport
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    // MARK: Lifecycle

    /// Starts the transport and performs the MCP `initialize` handshake.
    public func connect() async throws {
        guard !connected else { return }
        try await transport.start()
        startReadLoop()
        connected = true

        let result = try await request(method: "initialize", params: .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ]))

        serverInfo = MCPServerInfo(
            name: result["serverInfo"]?["name"]?.stringValue ?? "unknown",
            version: result["serverInfo"]?["version"]?.stringValue ?? "unknown",
            protocolVersion: result["protocolVersion"]?.stringValue ?? Self.protocolVersion,
            capabilities: result["capabilities"] ?? .object([:])
        )

        try await notify(method: "notifications/initialized")
    }

    /// Closes the transport; in-flight requests fail with
    /// ``AgentKitError/transportClosed``.
    public func close() async {
        connected = false
        readTask?.cancel()
        readTask = nil
        await transport.close()
        failAllPending()
    }

    // MARK: MCP methods

    /// Lists the tools the server exposes.
    public func listTools() async throws -> [MCPToolInfo] {
        let result = try await request(method: "tools/list", params: .object([:]))
        guard let tools = result["tools"]?.arrayValue else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            return MCPToolInfo(
                name: name,
                description: tool["description"]?.stringValue,
                inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")])
            )
        }
    }

    /// Calls a tool on the server.
    public func callTool(_ name: String, arguments: JSONValue = .object([:])) async throws -> MCPToolResult {
        let result = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]))
        var content: [MCPContent] = []
        for block in result["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                content.append(.text(block["text"]?.stringValue ?? ""))
            case "image":
                content.append(.image(
                    base64: block["data"]?.stringValue ?? "",
                    mimeType: block["mimeType"]?.stringValue ?? "application/octet-stream"
                ))
            default:
                content.append(.other(block))
            }
        }
        return MCPToolResult(content: content, isError: result["isError"]?.boolValue ?? false)
    }

    /// Bridges every server tool into a SwiftAgentKit ``Tool``, ready to
    /// hand to an ``Agent``. Tool errors surface as thrown errors so the
    /// agent loop reports them back to the model.
    public func tools() async throws -> [Tool] {
        let infos = try await listTools()
        return infos.map { info in
            Tool(
                name: info.name,
                description: info.description ?? "",
                parameters: JSONSchema(value: info.inputSchema)
            ) { arguments in
                let result = try await self.callTool(info.name, arguments: arguments)
                if result.isError {
                    throw AgentKitError.mcpError(code: -1, message: result.text)
                }
                return .string(result.text)
            }
        }
    }

    // MARK: JSON-RPC plumbing

    private func request(method: String, params: JSONValue?) async throws -> JSONValue {
        guard readTask != nil else {
            throw AgentKitError.transportClosed
        }
        let id = nextID
        nextID += 1
        let message = JSONRPCMessage.request(id: id, method: method, params: params)
        let data = try message.encodedLine()

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.transport.send(data)
                } catch {
                    self.fail(id: id, error: error)
                }
            }
        }
    }

    private func notify(method: String, params: JSONValue? = nil) async throws {
        let message = JSONRPCMessage.notification(method: method, params: params)
        try await transport.send(try message.encodedLine())
    }

    private func startReadLoop() {
        let stream = transport.messages
        readTask = Task { [weak self] in
            do {
                for try await data in stream {
                    await self?.handleIncoming(data)
                }
            } catch {
                // Stream errors fall through to cleanup below.
            }
            await self?.transportDidClose()
        }
    }

    private func handleIncoming(_ data: Data) async {
        guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else {
            return // Ignore malformed messages.
        }

        if message.isResponse {
            guard case .number(let id)? = message.id,
                  let continuation = pending.removeValue(forKey: id) else {
                return
            }
            if let error = message.error {
                continuation.resume(throwing: AgentKitError.mcpError(code: error.code, message: error.message))
            } else {
                continuation.resume(returning: message.result ?? .null)
            }
            return
        }

        // Server-initiated request or notification.
        guard let method = message.method else { return }
        if let id = message.id {
            // Answer pings; everything else is politely declined.
            let reply: JSONRPCMessage
            if method == "ping" {
                reply = .response(id: id, result: .object([:]))
            } else {
                reply = .errorResponse(
                    id: id,
                    code: JSONRPCError.methodNotFound,
                    message: "Method not supported: \(method)"
                )
            }
            if let data = try? reply.encodedLine() {
                try? await transport.send(data)
            }
        }
        // Notifications are currently ignored.
    }

    private func transportDidClose() {
        connected = false
        readTask = nil
        failAllPending()
    }

    private func fail(id: Int, error: Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func failAllPending() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: AgentKitError.transportClosed)
        }
    }
}
