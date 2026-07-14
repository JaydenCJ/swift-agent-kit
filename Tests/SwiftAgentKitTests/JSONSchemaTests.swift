import XCTest
@testable import SwiftAgentKit

final class JSONSchemaTests: XCTestCase {
    func testObjectBuilder() {
        let schema = JSONSchema.object(
            properties: [
                "city": .string(description: "City name"),
                "days": .integer(minimum: 1, maximum: 14),
            ],
            required: ["city"]
        )
        XCTAssertEqual(schema.type, "object")
        XCTAssertEqual(schema.required, ["city"])
        XCTAssertEqual(schema.properties?["city"]?.type, "string")
        XCTAssertEqual(schema.properties?["city"]?.value["description"], .string("City name"))
        XCTAssertEqual(schema.properties?["days"]?.value["minimum"], .int(1))
        XCTAssertEqual(schema.value["additionalProperties"], .bool(false))
    }

    func testObjectBuilderRequiresAllPropertiesByDefault() {
        let schema = JSONSchema.object(properties: [
            "b": .boolean(),
            "a": .number(),
        ])
        XCTAssertEqual(schema.required, ["a", "b"])
    }

    func testStringEnumBuilder() {
        let schema = JSONSchema.string(enumValues: ["celsius", "fahrenheit"])
        XCTAssertEqual(schema.type, "string")
        XCTAssertEqual(
            schema.value["enum"],
            .array([.string("celsius"), .string("fahrenheit")])
        )
    }

    func testArrayBuilder() {
        let schema = JSONSchema.array(of: .string(), minItems: 1)
        XCTAssertEqual(schema.type, "array")
        XCTAssertEqual(schema.items?.type, "string")
        XCTAssertEqual(schema.value["minItems"], .int(1))
    }

    func testAnyOfBuilder() {
        let schema = JSONSchema.anyOf([.string(), .null])
        XCTAssertEqual(schema.value["anyOf"]?[0]?["type"], .string("string"))
        XCTAssertEqual(schema.value["anyOf"]?[1]?["type"], .string("null"))
    }

    func testCodableRoundTrip() throws {
        let schema = JSONSchema.object(properties: ["q": .string()])
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }

    func testDescribed() {
        let schema = JSONSchema.integer().described("An amount")
        XCTAssertEqual(schema.value["description"], .string("An amount"))
        XCTAssertEqual(schema.type, "integer")
    }

    // MARK: containsOpenObject

    func testClosedObjectSchemaIsNotOpen() {
        let schema = JSONSchema.object(properties: [
            "city": .string(),
            "days": .integer(),
        ])
        XCTAssertFalse(schema.containsOpenObject)
    }

    func testBareObjectSchemaIsOpen() {
        // What inference emits for `[String: String]`.
        XCTAssertTrue(JSONSchema(value: ["type": "object"]).containsOpenObject)
    }

    func testAnySchemaIsOpen() {
        // What inference emits for `JSONValue`.
        XCTAssertTrue(JSONSchema.any.containsOpenObject)
    }

    func testOpenObjectIsDetectedWhenNested() {
        let inProperty = JSONSchema.object(properties: [
            "metadata": JSONSchema(value: ["type": "object"]),
        ])
        XCTAssertTrue(inProperty.containsOpenObject)

        let inArray = JSONSchema.array(of: JSONSchema(value: ["type": "object"]))
        XCTAssertTrue(inArray.containsOpenObject)

        let inAnyOf = JSONSchema.anyOf([.string(), JSONSchema.any])
        XCTAssertTrue(inAnyOf.containsOpenObject)
    }

    func testInferredDictionarySchemaIsOpen() throws {
        struct Wrapper: Codable {
            var metadata: [String: String]
        }
        let schema = try JSONSchema.infer(from: Wrapper.self)
        XCTAssertTrue(schema.containsOpenObject)
    }

    func testDeeplyClosedSchemaIsNotOpen() {
        let schema = JSONSchema.object(properties: [
            "items": .array(of: .object(properties: ["sku": .string()])),
            "choice": .anyOf([.string(), .integer()]),
        ])
        XCTAssertFalse(schema.containsOpenObject)
    }
}
