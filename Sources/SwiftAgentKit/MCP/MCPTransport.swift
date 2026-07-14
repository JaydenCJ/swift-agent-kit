import Foundation

/// A bidirectional MCP message pipe.
///
/// Implementations deliver *complete* JSON-RPC messages (one `Data` per
/// message) on ``messages`` — framing (newline splitting for stdio, SSE for
/// HTTP) is the transport's job, protocol logic lives in ``MCPClient``.
public protocol MCPTransport: Sendable {
    /// Starts the transport (spawn the process, open the connection, …).
    func start() async throws

    /// Sends one complete JSON-RPC message.
    func send(_ message: Data) async throws

    /// The stream of incoming complete JSON-RPC messages. Finishes when the
    /// transport closes.
    var messages: AsyncThrowingStream<Data, Error> { get }

    /// Closes the transport and releases resources.
    func close() async
}

#if !os(iOS) && !os(tvOS) && !os(watchOS) && !os(visionOS)
/// Speaks MCP's stdio transport: spawns a server subprocess and exchanges
/// newline-delimited JSON over its stdin/stdout. Available on macOS and
/// Linux (`Process` does not exist on iOS-family platforms).
///
/// ```swift
/// let transport = StdioTransport(
///     executable: "/usr/bin/npx",
///     arguments: ["-y", "@modelcontextprotocol/server-everything"]
/// )
/// let client = MCPClient(transport: transport)
/// try await client.connect()
/// ```
public final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?

    private let lock = NSLock()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var lineBuffer = Data()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    /// Incoming complete JSON-RPC messages from the server process.
    public let messages: AsyncThrowingStream<Data, Error>

    /// Creates a transport that will spawn `executable` with `arguments`
    /// (and an optional environment) on ``start()``.
    public init(executable: String, arguments: [String] = [], environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messages = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.finishStream(error: nil)
                return
            }
            self.consume(data)
        }

        process.terminationHandler = { [weak self] _ in
            self?.finishStream(error: nil)
        }

        do {
            try process.run()
        } catch {
            throw AgentKitError.transport("Failed to launch \(executable): \(error)")
        }

        lock.withLock {
            self.process = process
            self.stdinPipe = stdin
        }
    }

    public func send(_ message: Data) async throws {
        let pipe = lock.withLock { stdinPipe }
        guard let pipe else {
            throw AgentKitError.transportClosed
        }
        var framed = message
        if framed.last != UInt8(ascii: "\n") {
            framed.append(UInt8(ascii: "\n"))
        }
        pipe.fileHandleForWriting.write(framed)
    }

    public func close() async {
        let (process, stdin) = lock.withLock { () -> (Process?, Pipe?) in
            defer {
                self.process = nil
                self.stdinPipe = nil
            }
            return (self.process, self.stdinPipe)
        }
        try? stdin?.fileHandleForWriting.close()
        process?.terminate()
        finishStream(error: nil)
    }

    private func consume(_ data: Data) {
        let (lines, continuation) = lock.withLock {
            () -> ([Data], AsyncThrowingStream<Data, Error>.Continuation?) in
            lineBuffer.append(data)
            var lines: [Data] = []
            while let newline = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
                lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
                if !line.isEmpty {
                    lines.append(line)
                }
            }
            return (lines, self.continuation)
        }
        for line in lines {
            continuation?.yield(line)
        }
    }

    private func finishStream(error: Error?) {
        let continuation = lock.withLock {
            () -> AsyncThrowingStream<Data, Error>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}
#endif

/// An in-memory transport for tests and embedded servers: messages written
/// with ``send(_:)`` are handed to a handler, whose replies are delivered
/// back on ``messages``.
public final class InMemoryMCPTransport: MCPTransport, @unchecked Sendable {
    /// Receives each outgoing message and a callback that delivers replies.
    public typealias Handler = @Sendable (_ message: Data, _ reply: @Sendable (Data) -> Void) -> Void

    private let handler: Handler
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    /// Incoming replies produced by the handler.
    public let messages: AsyncThrowingStream<Data, Error>

    /// Creates a transport that routes every sent message to `handler`.
    public init(handler: @escaping Handler) {
        self.handler = handler
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messages = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() async throws {}

    public func send(_ message: Data) async throws {
        let deliver: @Sendable (Data) -> Void = { [weak self] reply in
            guard let self else { return }
            let continuation = self.lock.withLock { self.continuation }
            continuation?.yield(reply)
        }
        handler(message, deliver)
    }

    public func close() async {
        let continuation = lock.withLock {
            () -> AsyncThrowingStream<Data, Error>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }
}
