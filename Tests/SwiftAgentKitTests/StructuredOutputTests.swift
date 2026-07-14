import Foundation
import XCTest
@testable import SwiftAgentKit

final class StructuredOutputTests: XCTestCase {
    struct Recipe: Codable, Sendable, Equatable {
        var title: String
        var minutes: Int
    }

    // MARK: Lenient JSON extraction

    func testExtractPlainJSON() {
        let text = #"{"title": "Pasta", "minutes": 20}"#
        XCTAssertEqual(LenientJSON.extractDocument(from: text), text)
    }

    func testExtractFromMarkdownFence() {
        let text = """
        Here you go:
        ```json
        {"title": "Pasta", "minutes": 20}
        ```
        Enjoy!
        """
        XCTAssertEqual(
            LenientJSON.extractDocument(from: text),
            #"{"title": "Pasta", "minutes": 20}"#
        )
    }

    func testExtractFromProse() {
        let text = #"Sure! The answer is {"title": "Pasta", "minutes": 20} — hope that helps."#
        XCTAssertEqual(
            LenientJSON.extractDocument(from: text),
            #"{"title": "Pasta", "minutes": 20}"#
        )
    }

    func testExtractionIsStringLiteralAware() {
        // Braces inside string values must not unbalance the scanner.
        let text = #"{"note": "use { and } carefully", "n": 1} trailing"#
        XCTAssertEqual(
            LenientJSON.extractDocument(from: text),
            #"{"note": "use { and } carefully", "n": 1}"#
        )
    }

    func testExtractionHandlesEscapedQuotesInStrings() {
        let text = #"{"quote": "she said \"hi\" {"}"#
        XCTAssertEqual(LenientJSON.extractDocument(from: text), text)
    }

    func testExtractTopLevelArray() {
        let text = #"[1, 2, {"x": 3}]"#
        XCTAssertEqual(LenientJSON.extractDocument(from: text), text)
    }

    func testExtractReturnsNilWithoutJSON() {
        XCTAssertNil(LenientJSON.extractDocument(from: "no json here at all"))
    }

    // MARK: generateObject

    func testGenerateObjectDecodesAndSendsSchema() async throws {
        let provider = ScriptedProvider(responses: [
            .text(#"{"title": "Miso Pasta", "minutes": 15}"#)
        ])
        let result = try await generateObject(
            Recipe.self,
            provider: provider,
            prompt: "A quick pasta recipe"
        )
        XCTAssertEqual(result.object, Recipe(title: "Miso Pasta", minutes: 15))
        XCTAssertEqual(result.rawText, #"{"title": "Miso Pasta", "minutes": 15}"#)

        // The provider must have received a JSON-Schema response format
        // inferred from Recipe. Closed schemas default to strict mode.
        guard case .jsonSchema(_, let schema, let strict) = provider.requests[0].responseFormat else {
            return XCTFail("expected jsonSchema response format")
        }
        XCTAssertEqual(schema.properties?["title"]?.type, "string")
        XCTAssertEqual(schema.properties?["minutes"]?.type, "integer")
        XCTAssertTrue(strict)
    }

    func testGenerateObjectWithDictionaryPropertyDefaultsToNonStrict() async throws {
        // Strict json_schema modes reject open objects, which is what a
        // dictionary property infers to — the request must not be strict.
        struct Tagged: Codable, Sendable {
            var title: String
            var metadata: [String: String]
        }
        let provider = ScriptedProvider(responses: [
            .text(#"{"title": "x", "metadata": {"k": "v"}}"#)
        ])
        let result = try await generateObject(Tagged.self, provider: provider, prompt: "x")
        XCTAssertEqual(result.object.metadata, ["k": "v"])
        guard case .jsonSchema(_, _, let strict) = provider.requests[0].responseFormat else {
            return XCTFail("expected jsonSchema response format")
        }
        XCTAssertFalse(strict)
    }

    func testGenerateObjectStrictOverrideWins() async throws {
        struct Tagged: Codable, Sendable {
            var metadata: [String: String]
        }
        let provider = ScriptedProvider(responses: [
            .text(#"{"metadata": {}}"#)
        ])
        _ = try await generateObject(Tagged.self, provider: provider, prompt: "x", strict: true)
        guard case .jsonSchema(_, _, let strict) = provider.requests[0].responseFormat else {
            return XCTFail("expected jsonSchema response format")
        }
        XCTAssertTrue(strict)
    }

    func testGenerateObjectSurvivesFencedOutput() async throws {
        let provider = ScriptedProvider(responses: [
            .text("```json\n{\"title\": \"Soup\", \"minutes\": 40}\n```")
        ])
        let result = try await generateObject(Recipe.self, provider: provider, prompt: "soup")
        XCTAssertEqual(result.object.title, "Soup")
    }

    func testGenerateObjectFailureCarriesRawText() async {
        let provider = ScriptedProvider(responses: [
            .text(#"{"title": "Missing minutes"}"#)
        ])
        do {
            _ = try await generateObject(Recipe.self, provider: provider, prompt: "x")
            XCTFail("expected decoding failure")
        } catch let AgentKitError.objectDecodingFailed(_, rawText) {
            XCTAssertTrue(rawText.contains("Missing minutes"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGenerateObjectWithoutJSONInReplyThrows() async {
        let provider = ScriptedProvider(responses: [.text("I cannot answer in JSON, sorry.")])
        do {
            _ = try await generateObject(Recipe.self, provider: provider, prompt: "x")
            XCTFail("expected failure")
        } catch let AgentKitError.objectDecodingFailed(underlying, _) {
            XCTAssertTrue(underlying.contains("No JSON document"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGenerateObjectWithExplicitSchemaSkipsInference() async throws {
        // A type inference can't handle (non-CaseIterable enum) works when
        // an explicit schema is supplied.
        enum Mood: String, Codable, Sendable { case happy, sad }
        struct Entry: Codable, Sendable { var mood: Mood }

        let provider = ScriptedProvider(responses: [.text(#"{"mood": "happy"}"#)])
        let schema = JSONSchema.object(properties: [
            "mood": .string(enumValues: ["happy", "sad"]),
        ])
        let result = try await generateObject(
            Entry.self,
            provider: provider,
            prompt: "x",
            schema: schema
        )
        XCTAssertEqual(result.object.mood, .happy)
    }
}
