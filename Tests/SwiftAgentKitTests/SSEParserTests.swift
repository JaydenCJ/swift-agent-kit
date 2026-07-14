import XCTest
@testable import SwiftAgentKit

final class SSEParserTests: XCTestCase {
    func testSimpleEvent() {
        var parser = SSEParser()
        let events = parser.feed("data: hello\n\n")
        XCTAssertEqual(events, [SSEParser.Event(data: "hello")])
    }

    func testChunkSplitMidLine() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("da"), [])
        XCTAssertEqual(parser.feed("ta: hel"), [])
        XCTAssertEqual(parser.feed("lo\n"), [])
        let events = parser.feed("\n")
        XCTAssertEqual(events, [SSEParser.Event(data: "hello")])
    }

    func testCRLFLineEndings() {
        var parser = SSEParser()
        let events = parser.feed("data: a\r\ndata: b\r\n\r\n")
        XCTAssertEqual(events, [SSEParser.Event(data: "a\nb")])
    }

    func testCRLFSplitBetweenChunks() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("data: x\r"), [])
        let events = parser.feed("\n\r\n")
        XCTAssertEqual(events, [SSEParser.Event(data: "x")])
    }

    func testMultiLineDataJoinedWithNewline() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        XCTAssertEqual(events.first?.data, "line1\nline2")
    }

    func testCommentsAreIgnored()  {
        var parser = SSEParser()
        let events = parser.feed(": keep-alive\n\ndata: real\n\n")
        XCTAssertEqual(events, [SSEParser.Event(data: "real")])
    }

    func testEventNameAndID() {
        var parser = SSEParser()
        let events = parser.feed("event: message_start\nid: 42\ndata: {}\n\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message_start")
        XCTAssertEqual(events[0].id, "42")
        XCTAssertEqual(events[0].data, "{}")
    }

    func testEventNameResetsAfterDispatch() {
        var parser = SSEParser()
        let events = parser.feed("event: first\ndata: 1\n\ndata: 2\n\n")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "first")
        XCTAssertNil(events[1].event)
    }

    func testValueWithoutSpaceAfterColon() {
        var parser = SSEParser()
        let events = parser.feed("data:tight\n\n")
        XCTAssertEqual(events.first?.data, "tight")
    }

    func testOnlyFirstSpaceIsStripped() {
        var parser = SSEParser()
        let events = parser.feed("data:  padded\n\n")
        XCTAssertEqual(events.first?.data, " padded")
    }

    func testRetryField() {
        var parser = SSEParser()
        let events = parser.feed("retry: 1500\ndata: x\n\n")
        XCTAssertEqual(events.first?.retry, 1500)
    }

    func testMultipleEventsInOneChunk() {
        var parser = SSEParser()
        let events = parser.feed("data: 1\n\ndata: 2\n\ndata: 3\n\n")
        XCTAssertEqual(events.map(\.data), ["1", "2", "3"])
    }

    func testFinishFlushesPendingEventWithoutTrailingBlankLine() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("data: tail"), [])
        let final = parser.finish()
        XCTAssertEqual(final?.data, "tail")
    }

    func testFinishReturnsNilWhenNothingPending() {
        var parser = SSEParser()
        _ = parser.feed("data: done\n\n")
        XCTAssertNil(parser.finish())
    }

    func testEmptyDataLinesDoNotDispatch() {
        var parser = SSEParser()
        let events = parser.feed("event: nothing\n\n")
        XCTAssertEqual(events, [])
    }

    func testBOMIsStripped() {
        var parser = SSEParser()
        let events = parser.feed("\u{FEFF}data: x\n\n")
        XCTAssertEqual(events.first?.data, "x")
    }

    // MARK: UTF-8 chunk boundaries

    func testMultiByteUTF8SplitAtEveryPossibleBoundary() {
        // CJK (3-byte scalars) and an emoji (4-byte scalar): a network chunk
        // boundary may fall inside any of them.
        let text = "你好、世界 🌍 こんにちは"
        let payload = Array("data: \(text)\n\n".utf8)
        for split in 1..<payload.count {
            var parser = SSEParser()
            var events = parser.feed(Data(payload[..<split]))
            events += parser.feed(Data(payload[split...]))
            XCTAssertEqual(events, [SSEParser.Event(data: text)], "split at byte \(split)")
        }
    }

    func testUTF8FedOneByteAtATime() {
        let text = "中文 🚀 日本語"
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        for byte in "data: \(text)\n\n".utf8 {
            events += parser.feed(Data([byte]))
        }
        XCTAssertEqual(events, [SSEParser.Event(data: text)])
    }

    func testBOMSplitAcrossChunks() {
        var parser = SSEParser()
        let bytes = Array("\u{FEFF}data: x\n\n".utf8)
        XCTAssertEqual(parser.feed(Data(bytes[..<2])), []) // mid-BOM
        let events = parser.feed(Data(bytes[2...]))
        XCTAssertEqual(events, [SSEParser.Event(data: "x")])
    }

    func testInvalidUTF8IsReplacedNotHeldBack() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("data: ".utf8)), [])
        // 0xFF is never valid in UTF-8: it must decode to U+FFFD immediately
        // rather than being buffered as a "truncated" scalar forever.
        XCTAssertEqual(parser.feed(Data([0xFF])), [])
        let events = parser.feed(Data("x\n\n".utf8))
        XCTAssertEqual(events.first?.data, "\u{FFFD}x")
    }

    func testFinishDecodesPendingTruncatedScalar() {
        var parser = SSEParser()
        var bytes = Array("data: ok".utf8)
        bytes.append(0xE4) // first byte of a 3-byte scalar that never completes
        XCTAssertEqual(parser.feed(Data(bytes)), [])
        let final = parser.finish()
        XCTAssertEqual(final?.data, "ok\u{FFFD}")
    }
}
