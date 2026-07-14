import Foundation
import XCTest
@testable import SwiftAgentKit

final class ToolTests: XCTestCase {
    struct WeatherQuery: Codable, Sendable {
        var city: String
        var unit: String?
    }

    func testTypedToolInfersSchemaAndDecodesArguments() async throws {
        let tool = try Tool.typed(
            name: "get_weather",
            description: "Weather for a city"
        ) { (query: WeatherQuery) in
            "Sunny in \(query.city) (\(query.unit ?? "celsius"))"
        }

        XCTAssertEqual(tool.name, "get_weather")
        XCTAssertEqual(tool.parameters.type, "object")
        XCTAssertEqual(tool.parameters.properties?["city"]?.type, "string")
        XCTAssertEqual(tool.parameters.required, ["city"])

        let output = try await tool.execute(["city": "Berlin"])
        XCTAssertEqual(output, .string("Sunny in Berlin (celsius)"))
    }

    func testTypedToolEncodesStructuredOutput() async throws {
        struct Forecast: Codable, Sendable {
            var high: Int
            var low: Int
        }
        let tool = try Tool.typed(
            name: "forecast",
            description: "Numeric forecast"
        ) { (query: WeatherQuery) in
            Forecast(high: 25, low: 12)
        }
        let output = try await tool.execute(["city": "Rome"])
        XCTAssertEqual(output, ["high": 25, "low": 12])
        // Rendered form for tool messages is canonical JSON.
        XCTAssertEqual(Tool.renderOutput(output), #"{"high":25,"low":12}"#)
    }

    func testTypedToolRejectsInvalidArguments() async throws {
        let tool = try Tool.typed(
            name: "get_weather",
            description: ""
        ) { (query: WeatherQuery) in "ok" }

        do {
            _ = try await tool.execute(["city": 42])
            XCTFail("expected invalid arguments error")
        } catch let AgentKitError.invalidToolArguments(toolName, _) {
            XCTAssertEqual(toolName, "get_weather")
        }
    }

    func testExplicitSchemaOverridesInference() throws {
        let custom = JSONSchema.object(properties: ["city": .string(description: "custom")])
        let tool = try Tool.typed(
            name: "t",
            description: "",
            parameters: custom
        ) { (query: WeatherQuery) in "x" }
        XCTAssertEqual(tool.parameters, custom)
    }

    func testRenderOutputPassesStringsThrough() {
        XCTAssertEqual(Tool.renderOutput(.string("plain")), "plain")
        XCTAssertEqual(Tool.renderOutput(.int(7)), "7")
    }

    func testDefinitionMirrorsTool() {
        let tool = Tool(name: "n", description: "d", parameters: .any) { _ in .null }
        XCTAssertEqual(tool.definition, ToolDefinition(name: "n", description: "d", parameters: .any))
    }
}
