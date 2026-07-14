import Foundation
import XCTest
@testable import SwiftAgentKit

/// Guards the README Quickstart: the code between the markers below is the
/// minimal example from README.md (step 3), kept identical byte-for-byte
/// (modulo indentation). If this test stops compiling or passing, the README
/// is lying — fix both together.
final class ReadmeExampleTests: XCTestCase {
    func testReadmeMinimalExampleRunsVerbatim() async throws {
        // A scripted provider stands in for the model so the example runs
        // without any server or network, exactly like the offline demo.
        let provider: any ModelProvider = ScriptedProvider(responses: [
            .toolCalls([
                ToolCall(
                    id: "call_1",
                    name: "get_calendar_events",
                    arguments: ["day": .string("tomorrow")]
                )
            ]),
            .text("Tomorrow: 10:30 Dentist, 19:00 Dinner with Yuki."),
        ])

        // --- README Quickstart minimal example (verbatim) ---
        struct CalendarQuery: Codable { var day: String }
        let calendar = try Tool.typed(
            name: "get_calendar_events",
            description: "Return the calendar events for a day ('today' or 'tomorrow')."
        ) { (query: CalendarQuery) in
            query.day == "tomorrow" ? "10:30 Dentist, 19:00 Dinner with Yuki" : "No events."
        }
        let agent = Agent(provider: provider, tools: [calendar])
        let answer = try await agent.run("What's on my calendar tomorrow?")
        print(answer.text)
        // --- end README example ---

        XCTAssertEqual(answer.text, "Tomorrow: 10:30 Dentist, 19:00 Dinner with Yuki.")
        XCTAssertEqual(answer.steps.count, 2)
        let record = try XCTUnwrap(answer.steps.first?.toolResults.first)
        XCTAssertEqual(record.toolName, "get_calendar_events")
        XCTAssertEqual(record.outputText, "10:30 Dentist, 19:00 Dinner with Yuki")
        XCTAssertFalse(record.isError)
    }

    func testReadmeExampleToolHandlesTheOtherBranch() async throws {
        // The example's tool returns the fallback string for any other day;
        // the agent feeds that result back to the model unchanged.
        let provider: any ModelProvider = ScriptedProvider(responses: [
            .toolCalls([
                ToolCall(
                    id: "call_1",
                    name: "get_calendar_events",
                    arguments: ["day": .string("today")]
                )
            ]),
            .text("Nothing scheduled."),
        ])
        struct CalendarQuery: Codable { var day: String }
        let calendar = try Tool.typed(
            name: "get_calendar_events",
            description: "Return the calendar events for a day ('today' or 'tomorrow')."
        ) { (query: CalendarQuery) in
            query.day == "tomorrow" ? "10:30 Dentist, 19:00 Dinner with Yuki" : "No events."
        }
        let agent = Agent(provider: provider, tools: [calendar])
        let answer = try await agent.run("What's on my calendar today?")
        XCTAssertEqual(answer.steps.first?.toolResults.first?.outputText, "No events.")
        XCTAssertEqual(answer.text, "Nothing scheduled.")
    }
}
