import Foundation
import XCTest
@testable import SwiftAgentKit

/// A scripted MCP server behind an in-memory transport.
final class ScriptedMCPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [JSONRPCMessage] = []
    /// Method name → result payload.
    var results: [String: JSONValue]
    /// Method name → error to return instead of a result.
    var errors: [String: JSONRPCError] = [:]

    init(results: [String: JSONValue] = [:]) {
        self.results = results
    }

    var receivedMessages: [JSONRPCMessage] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func makeTransport() -> InMemoryMCPTransport {
        InMemoryMCPTransport { [self] data, reply in
            guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else { return }
            lock.lock()
            received.append(message)
            let error = message.method.flatMap { errors[$0] }
            let result = message.method.flatMap { results[$0] }
            lock.unlock()

            guard let id = message.id else { return } // notification: no reply
            if let error {
                let response = JSONRPCMessage(id: id, error: error)
                if let encoded = try? response.encodedLine() { reply(encoded) }
            } else {
                let response = JSONRPCMessage.response(id: id, result: result ?? .object([:]))
                if let encoded = try? response.encodedLine() { reply(encoded) }
            }
        }
    }
}

private let initializeResult: JSONValue = [
    "protocolVersion": "2025-06-18",
    "capabilities": ["tools": [:]],
    "serverInfo": ["name": "test-server", "version": "9.9.9"],
]

final class MCPClientTests: XCTestCase {
    func testInitializeHandshake() async throws {
        let server = ScriptedMCPServer(results: ["initialize": initializeResult])
        let client = MCPClient(transport: server.makeTransport())
        try await client.connect()

        let info = await client.serverInfo
        XCTAssertEqual(info?.name, "test-server")
        XCTAssertEqual(info?.version, "9.9.9")
        XCTAssertEqual(info?.protocolVersion, "2025-06-18")

        let messages = server.receivedMessages
        XCTAssertEqual(messages.count, 2)
        // 1. initialize request with protocol version and client info.
        XCTAssertEqual(messages[0].method, "initialize")
        XCTAssertEqual(messages[0].params?["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(messages[0].params?["clientInfo"]?["name"], .string("SwiftAgentKit"))
        XCTAssertNotNil(messages[0].id)
        // 2. initialized notification (no id).
        XCTAssertEqual(messages[1].method, "notifications/initialized")
        XCTAssertNil(messages[1].id)
    }

    func testListTools() async throws {
        let server = ScriptedMCPServer(results: [
            "initialize": initializeResult,
            "tools/list": [
                "tools": [
                    [
                        "name": "read_file",
                        "description": "Reads a file",
                        "inputSchema": ["type": "object", "properties": ["path": ["type": "string"]]],
                    ],
                    ["name": "no_description"],
                ],
            ],
        ])
        let client = MCPClient(transport: server.makeTransport())
        try await client.connect()

        let tools = try await client.listTools()
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0].name, "read_file")
        XCTAssertEqual(tools[0].description, "Reads a file")
        XCTAssertEqual(tools[0].inputSchema["properties"]?["path"]?["type"], .string("string"))
        XCTAssertEqual(tools[1].name, "no_description")
        XCTAssertNil(tools[1].description)
    }

    func testCallToolParsesContent() async throws {
        let server = ScriptedMCPServer(results: [
            "initialize": initializeResult,
            "tools/call": [
                "content": [
                    ["type": "text", "text": "line one"],
                    ["type": "text", "text": "line two"],
                    ["type": "image", "data": "aGk=", "mimeType": "image/png"],
                ],
                "isError": false,
            ],
        ])
        let client = MCPClient(transport: server.makeTransport())
        try await client.connect()

        let result = try await client.callTool("read_file", arguments: ["path": "/tmp/x"])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "line one\nline two")
        XCTAssertEqual(result.content.count, 3)
        XCTAssertEqual(result.content[2], .image(base64: "aGk=", mimeType: "image/png"))

        // Arguments must be forwarded verbatim.
        let call = server.receivedMessages.first { $0.method == "tools/call" }
        XCTAssertEqual(call?.params?["name"], .string("read_file"))
        XCTAssertEqual(call?.params?["arguments"]?["path"], .string("/tmp/x"))
    }

    func testServerErrorSurfacesAsThrownError() async throws {
        let server = ScriptedMCPServer(results: ["initialize": initializeResult])
        server.errors["tools/call"] = JSONRPCError(code: -32602, message: "unknown tool")
        let client = MCPClient(transport: server.makeTransport())
        try await client.connect()

        do {
            _ = try await client.callTool("nope")
            XCTFail("expected an MCP error")
        } catch let AgentKitError.mcpError(code, message) {
            XCTAssertEqual(code, -32602)
            XCTAssertEqual(message, "unknown tool")
        }
    }

    func testOutOfOrderResponsesMatchByID() async throws {
        // A transport that answers the first two tools/call requests in
        // reverse order.
        let held = Locked<[(id: JSONRPCID, name: String)]>([])

        let transport = InMemoryMCPTransport { data, reply in
            guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data),
                  let id = message.id else { return }
            switch message.method {
            case "initialize":
                reply(try! JSONRPCMessage.response(id: id, result: initializeResult).encodedLine())
            case "tools/call":
                let name = message.params?["name"]?.stringValue ?? "?"
                let ready: [(id: JSONRPCID, name: String)] = held.withLock { entries in
                    entries.append((id, name))
                    if entries.count == 2 {
                        let both = entries
                        entries = []
                        return both
                    }
                    return []
                }
                // Answer both, in reverse arrival order.
                for entry in ready.reversed() {
                    let result: JSONValue = [
                        "content": [["type": "text", "text": .string("result-for-\(entry.name)")]],
                    ]
                    reply(try! JSONRPCMessage.response(id: entry.id, result: result).encodedLine())
                }
            default:
                break
            }
        }

        let client = MCPClient(transport: transport)
        try await client.connect()

        async let first = client.callTool("alpha")
        async let second = client.callTool("beta")
        let (a, b) = try await (first, second)

        // Each caller gets *its own* result despite reversed reply order.
        XCTAssertEqual(a.text, "result-for-alpha")
        XCTAssertEqual(b.text, "result-for-beta")
    }

    func testPingIsAnsweredAutomatically() async throws {
        let replyBox = Locked<JSONRPCMessage?>(nil)

        let transport = InMemoryMCPTransport { data, reply in
            guard let message = try? JSONDecoder().decode(JSONRPCMessage.self, from: data) else { return }
            if message.method == "initialize", let id = message.id {
                reply(try! JSONRPCMessage.response(id: id, result: initializeResult).encodedLine())
                // After initialize, the "server" pings the client.
                reply(try! JSONRPCMessage.request(id: 777, method: "ping").encodedLine())
            }
            if message.isResponse, message.id == .number(777) {
                replyBox.withLock { $0 = message }
            }
        }

        let client = MCPClient(transport: transport)
        try await client.connect()

        // Wait (up to ~2s) for the client's automatic pong.
        for _ in 0..<200 where replyBox.value == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let response = replyBox.value
        XCTAssertNotNil(response, "client never answered the ping")
        XCTAssertEqual(response?.result, .object([:]))
        XCTAssertNil(response?.error)
        await client.close()
    }

    func testBridgedToolsExecuteThroughClient() async throws {
        let server = ScriptedMCPServer(results: [
            "initialize": initializeResult,
            "tools/list": [
                "tools": [[
                    "name": "greet",
                    "description": "Greets",
                    "inputSchema": ["type": "object", "properties": ["who": ["type": "string"]]],
                ]],
            ],
            "tools/call": [
                "content": [["type": "text", "text": "hello, world"]],
            ],
        ])
        let client = MCPClient(transport: server.makeTransport())
        try await client.connect()

        let tools = try await client.tools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "greet")
        XCTAssertEqual(tools[0].parameters.properties?["who"]?.type, "string")

        let output = try await tools[0].execute(["who": "world"])
        XCTAssertEqual(output, .string("hello, world"))
    }

    func testRequestsFailWhenTransportCloses() async throws {
        let server = ScriptedMCPServer(results: ["initialize": initializeResult])
        let transport = server.makeTransport()
        let client = MCPClient(transport: transport)
        try await client.connect()
        await client.close()

        do {
            _ = try await client.listTools()
            XCTFail("expected transportClosed")
        } catch AgentKitError.transportClosed {
            // expected
        }
    }
}
