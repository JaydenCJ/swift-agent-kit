import Foundation
import XCTest
@testable import SwiftAgentKit

final class ChatMessageTests: XCTestCase {
    func testConveniences() {
        let system = ChatMessage.system("You are terse.")
        XCTAssertEqual(system.role, .system)
        XCTAssertEqual(system.text, "You are terse.")

        let user = ChatMessage.user("Hi")
        XCTAssertEqual(user.role, .user)

        let assistant = ChatMessage.assistant("Hello!")
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertTrue(assistant.toolCalls.isEmpty)

        let tool = ChatMessage.tool(callID: "call_1", name: "clock", content: "12:00", isError: false)
        XCTAssertEqual(tool.role, .tool)
        XCTAssertEqual(tool.toolCallID, "call_1")
        XCTAssertEqual(tool.name, "clock")
        XCTAssertNil(tool.isToolError)
    }

    func testToolErrorFlag() {
        let tool = ChatMessage.tool(callID: "c", content: "boom", isError: true)
        XCTAssertEqual(tool.isToolError, true)
    }

    func testTextJoinsOnlyTextParts() {
        let message = ChatMessage.user([
            .text("look at this:"),
            .imageURL("https://example.com/cat.png"),
            .text("cute, right?"),
        ])
        XCTAssertEqual(message.text, "look at this:\ncute, right?")
    }

    func testCodableRoundTripWithToolCalls() throws {
        let original = ChatMessage.assistant(
            "Checking…",
            toolCalls: [ToolCall(id: "call_9", name: "search", arguments: ["q": "swift"])]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingAcceptsBareStringContent() throws {
        let json = #"{"role": "user", "content": "plain text"}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.content, [.text("plain text")])
    }

    func testImageDataPartRoundTrip() throws {
        let part = ContentPart.imageData(Data([1, 2, 3]), mimeType: "image/png")
        let data = try JSONEncoder().encode([part])
        let decoded = try JSONDecoder().decode([ContentPart].self, from: data)
        XCTAssertEqual(decoded, [part])
    }
}
