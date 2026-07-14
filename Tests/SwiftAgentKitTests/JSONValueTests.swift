import XCTest
@testable import SwiftAgentKit

final class JSONValueTests: XCTestCase {
    func testLiteralsAndEquality() {
        let value: JSONValue = [
            "name": "swift",
            "stars": 5000,
            "score": 4.5,
            "active": true,
            "tags": ["llm", "agent"],
            "missing": nil,
        ]
        XCTAssertEqual(value["name"], .string("swift"))
        XCTAssertEqual(value["stars"], .int(5000))
        XCTAssertEqual(value["score"], .double(4.5))
        XCTAssertEqual(value["active"], .bool(true))
        XCTAssertEqual(value["tags"], .array([.string("llm"), .string("agent")]))
        XCTAssertEqual(value["missing"], .null)
        XCTAssertNil(value["absent"])
    }

    func testDecodeFromJSONData() throws {
        let json = #"{"a": 1, "b": 2.5, "c": "x", "d": true, "e": null, "f": [1, "two"], "g": {"h": false}}"#
        let value = try JSONValue(parsing: json)
        XCTAssertEqual(value["a"], .int(1))
        XCTAssertEqual(value["b"], .double(2.5))
        XCTAssertEqual(value["c"], .string("x"))
        XCTAssertEqual(value["d"], .bool(true))
        XCTAssertEqual(value["e"], .null)
        XCTAssertEqual(value["f"]?[0], .int(1))
        XCTAssertEqual(value["f"]?[1], .string("two"))
        XCTAssertEqual(value["g"]?["h"], .bool(false))
    }

    func testBoolsAreNotConfusedWithNumbers() throws {
        let value = try JSONValue(parsing: #"{"flag": true, "count": 1}"#)
        XCTAssertEqual(value["flag"], .bool(true))
        XCTAssertEqual(value["count"], .int(1))
        XCTAssertNotEqual(value["flag"], .int(1))
    }

    func testEncodeDecodeRoundTrip() throws {
        let original: JSONValue = [
            "text": "hé\"llo\n",
            "n": 42,
            "list": [true, nil, 1.25],
            "nested": ["k": "v"],
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCanonicalStringSortsKeysDeterministically() {
        let value: JSONValue = ["zebra": 1, "alpha": 2, "mid": ["b": 1, "a": 2]]
        XCTAssertEqual(
            value.canonicalJSONString(),
            #"{"alpha":2,"mid":{"a":2,"b":1},"zebra":1}"#
        )
    }

    func testCanonicalStringEscaping() {
        let value: JSONValue = ["s": "line1\nline2\t\"quoted\"\\end\u{01}"]
        XCTAssertEqual(
            value.canonicalJSONString(),
            #"{"s":"line1\nline2\t\"quoted\"\\end\u0001"}"#
        )
    }

    func testCanonicalStringRoundTripsThroughParser() throws {
        let value: JSONValue = ["a": [1, 2.5, "三", true, nil], "b": ["c": "d\ne"]]
        let reparsed = try JSONValue(parsing: value.canonicalJSONString())
        XCTAssertEqual(reparsed, value)
    }

    func testSubscripts() {
        let value: JSONValue = ["items": [["id": 7]]]
        XCTAssertEqual(value["items"]?[0]?["id"]?.intValue, 7)
        XCTAssertNil(value["items"]?[5])
        XCTAssertNil(value[0])
    }

    func testNumericAccessors() {
        XCTAssertEqual(JSONValue.int(3).doubleValue, 3.0)
        XCTAssertEqual(JSONValue.double(3.0).intValue, 3)
        XCTAssertNil(JSONValue.double(3.5).intValue)
        XCTAssertNil(JSONValue.string("3").intValue)
    }

    func testTypedBridging() throws {
        struct Point: Codable, Equatable {
            var x: Int
            var y: Int
        }
        let value = try JSONValue(encoding: Point(x: 1, y: 2))
        XCTAssertEqual(value, ["x": 1, "y": 2])
        let point: Point = try value.decode()
        XCTAssertEqual(point, Point(x: 1, y: 2))
    }
}
