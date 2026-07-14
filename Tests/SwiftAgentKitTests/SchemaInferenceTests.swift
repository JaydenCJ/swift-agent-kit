import Foundation
import XCTest
@testable import SwiftAgentKit

final class SchemaInferenceTests: XCTestCase {
    func testFlatStructPrimitives() throws {
        struct Query: Codable {
            var city: String
            var count: Int
            var ratio: Double
            var enabled: Bool
        }
        let schema = try JSONSchema.infer(from: Query.self)
        XCTAssertEqual(schema.type, "object")
        XCTAssertEqual(schema.properties?["city"]?.type, "string")
        XCTAssertEqual(schema.properties?["count"]?.type, "integer")
        XCTAssertEqual(schema.properties?["ratio"]?.type, "number")
        XCTAssertEqual(schema.properties?["enabled"]?.type, "boolean")
        XCTAssertEqual(schema.required?.sorted(), ["city", "count", "enabled", "ratio"])
    }

    func testOptionalPropertiesAreNotRequired() throws {
        struct Query: Codable {
            var name: String
            var nickname: String?
            var age: Int?
        }
        let schema = try JSONSchema.infer(from: Query.self)
        XCTAssertEqual(schema.required, ["name"])
        // Optional properties still get typed schemas.
        XCTAssertEqual(schema.properties?["nickname"]?.type, "string")
        XCTAssertEqual(schema.properties?["age"]?.type, "integer")
    }

    func testNestedStruct() throws {
        struct Address: Codable {
            var street: String
            var zip: String
        }
        struct Person: Codable {
            var name: String
            var address: Address
        }
        let schema = try JSONSchema.infer(from: Person.self)
        let address = schema.properties?["address"]
        XCTAssertEqual(address?.type, "object")
        XCTAssertEqual(address?.properties?["street"]?.type, "string")
        XCTAssertEqual(address?.required?.sorted(), ["street", "zip"])
    }

    func testArrayOfStrings() throws {
        struct Query: Codable {
            var tags: [String]
        }
        let schema = try JSONSchema.infer(from: Query.self)
        let tags = schema.properties?["tags"]
        XCTAssertEqual(tags?.type, "array")
        XCTAssertEqual(tags?.items?.type, "string")
    }

    func testArrayOfStructs() throws {
        struct Item: Codable {
            var sku: String
            var quantity: Int
        }
        struct Order: Codable {
            var items: [Item]
        }
        let schema = try JSONSchema.infer(from: Order.self)
        let items = schema.properties?["items"]
        XCTAssertEqual(items?.type, "array")
        XCTAssertEqual(items?.items?.type, "object")
        XCTAssertEqual(items?.items?.properties?["quantity"]?.type, "integer")
    }

    func testCaseIterableStringEnumBecomesEnumSchema() throws {
        enum Unit: String, Codable, CaseIterable {
            case celsius
            case fahrenheit
        }
        struct Query: Codable {
            var unit: Unit
        }
        let schema = try JSONSchema.infer(from: Query.self)
        let unit = schema.properties?["unit"]
        XCTAssertEqual(unit?.type, "string")
        XCTAssertEqual(
            unit?.value["enum"],
            .array([.string("celsius"), .string("fahrenheit")])
        )
        XCTAssertEqual(schema.required, ["unit"])
    }

    func testNonCaseIterableEnumThrowsHelpfully() {
        enum Mood: String, Codable {
            case happy
            case sad
        }
        struct Entry: Codable {
            var mood: Mood
        }
        XCTAssertThrowsError(try JSONSchema.infer(from: Entry.self)) { error in
            guard case AgentKitError.schemaInference(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("CaseIterable"), "message was: \(message)")
        }
    }

    func testFoundationTypes() throws {
        struct Record: Codable {
            var id: UUID
            var homepage: URL
            var created: Date
            var payload: Data
        }
        let schema = try JSONSchema.infer(from: Record.self)
        XCTAssertEqual(schema.properties?["id"]?.type, "string")
        XCTAssertEqual(schema.properties?["id"]?.value["format"], .string("uuid"))
        XCTAssertEqual(schema.properties?["homepage"]?.type, "string")
        XCTAssertEqual(schema.properties?["homepage"]?.value["format"], .string("uri"))
        XCTAssertEqual(schema.properties?["created"]?.type, "string")
        XCTAssertEqual(schema.properties?["created"]?.value["format"], .string("date-time"))
        XCTAssertEqual(schema.properties?["payload"]?.type, "string")
    }

    func testDictionaryBecomesOpenObject() throws {
        struct Wrapper: Codable {
            var metadata: [String: String]
        }
        let schema = try JSONSchema.infer(from: Wrapper.self)
        let metadata = schema.properties?["metadata"]
        XCTAssertEqual(metadata?.type, "object")
        // Open object: no fixed properties, no additionalProperties: false.
        XCTAssertNil(metadata?.value["additionalProperties"])
    }

    func testJSONValuePropertyBecomesAnySchema() throws {
        struct Wrapper: Codable {
            var anything: JSONValue
        }
        let schema = try JSONSchema.infer(from: Wrapper.self)
        XCTAssertEqual(schema.properties?["anything"], .any)
    }

    func testTopLevelArray() throws {
        let schema = try JSONSchema.infer(from: [Int].self)
        XCTAssertEqual(schema.type, "array")
        XCTAssertEqual(schema.items?.type, "integer")
    }

    func testInferredSchemaIsStableAcrossCalls() throws {
        struct Query: Codable {
            var a: String
            var b: Int
        }
        let first = try JSONSchema.infer(from: Query.self)
        let second = try JSONSchema.infer(from: Query.self)
        XCTAssertEqual(first.canonicalJSONString(), second.canonicalJSONString())
    }
}
