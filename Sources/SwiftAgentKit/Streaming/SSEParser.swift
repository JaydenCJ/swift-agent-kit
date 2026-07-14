import Foundation

/// An incremental Server-Sent Events (`text/event-stream`) parser.
///
/// Feed it raw chunks as they arrive off the wire — chunk boundaries may fall
/// anywhere, including mid-line, between `\r` and `\n`, or in the middle of
/// a multi-byte UTF-8 character — and it returns complete events as they are
/// dispatched. Implements the WHATWG
/// EventSource stream format: `data:`/`event:`/`id:`/`retry:` fields,
/// multi-line data joined with `\n`, `:` comments, and `\r\n`/`\r`/`\n`
/// line endings.
public struct SSEParser: Sendable {
    /// One dispatched server-sent event.
    public struct Event: Sendable, Equatable {
        /// The `event:` field, if any.
        public var event: String?
        /// The joined `data:` payload.
        public var data: String
        /// The `id:` field, if any.
        public var id: String?
        /// The `retry:` field in milliseconds, if any.
        public var retry: Int?

        /// Creates an event.
        public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
            self.event = event
            self.data = data
            self.id = id
            self.retry = retry
        }
    }

    /// Buffered input with line endings already normalized to `\n`.
    private var buffer: String = ""
    /// Trailing bytes of the previous chunk that were the incomplete prefix
    /// of a multi-byte UTF-8 scalar, held back until the rest arrives.
    private var pendingBytes = Data()
    /// Whether the previous chunk ended in `\r`, so a leading `\n` in the
    /// next chunk is the second half of a split `\r\n` and must be dropped.
    private var pendingCR = false
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastID: String?
    private var retry: Int?
    private var sawFirstChunk = false

    /// Creates an empty parser.
    public init() {}

    /// Feeds a UTF-8 chunk of the stream; returns any events completed by it.
    ///
    /// Chunk boundaries may fall *inside* a multi-byte UTF-8 scalar (common
    /// with CJK text or emoji on real networks): the incomplete trailing
    /// bytes are buffered and decoded together with the next chunk, so no
    /// character is ever mangled into U+FFFD by a badly placed boundary.
    public mutating func feed(_ data: Data) -> [Event] {
        var bytes: Data
        if pendingBytes.isEmpty {
            bytes = data
        } else {
            bytes = pendingBytes
            bytes.append(data)
            pendingBytes = Data()
        }
        let completeCount = Self.completeUTF8PrefixCount(of: bytes)
        if completeCount < bytes.count {
            pendingBytes = Data(bytes.suffix(bytes.count - completeCount))
            bytes = Data(bytes.prefix(completeCount))
        }
        guard !bytes.isEmpty else { return [] }
        return feed(String(decoding: bytes, as: UTF8.self))
    }

    /// Returns the length of the longest prefix of `bytes` that does not end
    /// mid-way through a multi-byte UTF-8 scalar. Bytes beyond it are the
    /// truncated start of a scalar whose remainder has not arrived yet.
    /// Genuinely invalid sequences are *not* held back — they are left to the
    /// decoder, which replaces them with U+FFFD as usual.
    private static func completeUTF8PrefixCount(of bytes: Data) -> Int {
        let count = bytes.count
        guard count > 0 else { return 0 }
        // Walk back over up to three continuation bytes (0b10xxxxxx) to the
        // lead byte of the last scalar in the buffer.
        var start = count - 1
        var stepsBack = 0
        while start > 0, stepsBack < 3,
              bytes[bytes.startIndex + start] & 0b1100_0000 == 0b1000_0000 {
            start -= 1
            stepsBack += 1
        }
        let lead = bytes[bytes.startIndex + start]
        let scalarLength: Int
        if lead & 0b1000_0000 == 0 {
            scalarLength = 1
        } else if lead & 0b1110_0000 == 0b1100_0000 {
            scalarLength = 2
        } else if lead & 0b1111_0000 == 0b1110_0000 {
            scalarLength = 3
        } else if lead & 0b1111_1000 == 0b1111_0000 {
            scalarLength = 4
        } else {
            // Stray continuation byte or invalid lead: not a truncated
            // scalar, decode it now (yielding U+FFFD).
            return count
        }
        let available = count - start
        return available < scalarLength ? start : count
    }

    /// Feeds a string chunk of the stream; returns any events completed by it.
    public mutating func feed(_ chunk: String) -> [Event] {
        var chunk = chunk
        if !sawFirstChunk {
            sawFirstChunk = true
            // Strip a UTF-8 BOM if present.
            if chunk.hasPrefix("\u{FEFF}") {
                chunk.removeFirst()
            }
        }
        // Normalize `\r\n` and lone `\r` to `\n` at the scalar level before
        // buffering. Working scalar-by-scalar matters twice over: a chunk
        // boundary may fall between `\r` and `\n`, and Swift's `Character`
        // view would otherwise fuse `\r\n` into a single grapheme cluster
        // that matches neither terminator.
        var normalized = String.UnicodeScalarView()
        for scalar in chunk.unicodeScalars {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { continue }
            }
            if scalar == "\r" {
                pendingCR = true
                normalized.append("\n")
            } else {
                normalized.append(scalar)
            }
        }
        buffer += String(normalized)

        var events: [Event] = []
        while let line = nextCompleteLine() {
            if let event = process(line: line) {
                events.append(event)
            }
        }
        return events
    }

    /// Signals end-of-stream; returns a final event if the stream ended
    /// without a trailing blank line but with pending data.
    public mutating func finish() -> Event? {
        var trailing: Event?
        // A held-back partial scalar can no longer be completed: decode it
        // (as U+FFFD) so its bytes are not silently dropped.
        if !pendingBytes.isEmpty {
            buffer += String(decoding: pendingBytes, as: UTF8.self)
            pendingBytes = Data()
        }
        pendingCR = false
        // Process whatever is left in the buffer as a final line.
        if !buffer.isEmpty {
            let line = buffer
            buffer = ""
            trailing = process(line: line)
        }
        if trailing == nil {
            trailing = dispatch()
        }
        dataLines = []
        eventType = nil
        return trailing
    }

    /// Extracts the next complete line from the buffer. Line endings were
    /// normalized to `\n` when the chunk was fed, so a plain newline search
    /// suffices here.
    private mutating func nextCompleteLine() -> String? {
        guard let newline = buffer.firstIndex(of: "\n") else { return nil }
        let line = String(buffer[buffer.startIndex..<newline])
        buffer.removeSubrange(buffer.startIndex...newline)
        return line
    }

    private mutating func process(line: String) -> Event? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil // comment
        }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") {
                value.removeFirst()
            }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "data":
            dataLines.append(value)
        case "event":
            eventType = value
        case "id":
            // Per spec, IDs containing NUL are ignored.
            if !value.contains("\u{0}") {
                lastID = value
            }
        case "retry":
            if let milliseconds = Int(value) {
                retry = milliseconds
            }
        default:
            break // unknown fields are ignored
        }
        return nil
    }

    private mutating func dispatch() -> Event? {
        defer {
            dataLines = []
            eventType = nil
        }
        guard !dataLines.isEmpty else {
            return nil
        }
        return Event(
            event: eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastID,
            retry: retry
        )
    }
}
