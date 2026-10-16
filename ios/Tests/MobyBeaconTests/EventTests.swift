import XCTest
@testable import MobyBeacon

final class EventTests: XCTestCase {
    func test_toJSONSerializesTimestampAsUTCISO8601() {
        let event = MobyBeaconEvent(userId: "user-1", category: "screen", action: "view",
                                    timestamp: ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!, details: nil)
        let json = event.toJSONObject()
        XCTAssertEqual(json["timestamp"] as? String, "2026-10-07T12:00:00.000Z")
        XCTAssertNil(json["details"])
        XCTAssertEqual(Set(json.keys), ["userId", "category", "action", "timestamp"])
    }

    func test_toJSONIncludesDetailsWhenPresent() {
        let event = MobyBeaconEvent(userId: "user-1", category: "survey", action: "answer",
                                    timestamp: ISO8601DateFormatter().date(from: "2026-10-07T00:00:00Z")!,
                                    details: ["question": 3, "value": "agree"])
        let details = event.toJSONObject()["details"] as? [String: Any]
        XCTAssertEqual(details?["question"] as? Int, 3)
        XCTAssertEqual(details?["value"] as? String, "agree")
        XCTAssertEqual(details?.count, 2)
    }

    func test_fromJSONRoundTripsToJSON() throws {
        let event = MobyBeaconEvent(userId: "user-1", category: "survey", action: "answer",
                                    timestamp: ISO8601DateFormatter().date(from: "2026-10-07T08:00:00Z")!,
                                    details: ["question": 3, "skipped": false, "note": NSNull()])
        let data = try JSONSerialization.data(withJSONObject: event.toJSONObject())
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let restored = try XCTUnwrap(MobyBeaconEvent(jsonObject: decoded))
        XCTAssertEqual(restored.userId, "user-1")
        XCTAssertEqual(restored.category, "survey")
        XCTAssertEqual(restored.action, "answer")
        XCTAssertEqual(restored.timestamp, event.timestamp)
        let again = try JSONSerialization.data(withJSONObject: restored.toJSONObject(), options: [.sortedKeys])
        let original = try JSONSerialization.data(withJSONObject: event.toJSONObject(), options: [.sortedKeys])
        XCTAssertEqual(again, original)
    }

    func test_eventBatchErrorFromJSONReadsIndexAndMessage() throws {
        let error = try XCTUnwrap(EventBatchError(jsonObject: ["index": 2, "message": "bad"]))
        XCTAssertEqual(error.index, 2)
        XCTAssertEqual(error.message, "bad")
        XCTAssertEqual(error, EventBatchError(index: 2, message: "bad"))
        XCTAssertEqual(error.hash, EventBatchError(index: 2, message: "bad").hash)
        XCTAssertNotEqual(error, EventBatchError(index: 3, message: "bad"))
        XCTAssertNil(EventBatchError(jsonObject: ["index": 2]))
    }

    func test_fromJSONProducesACopyOfDetails() throws {
        var source: [String: Any] = ["question": 3]
        let event = try XCTUnwrap(MobyBeaconEvent(jsonObject: [
            "userId": "user-1", "category": "survey", "action": "answer",
            "timestamp": "2026-10-07T08:00:00.000Z", "details": source,
        ]))
        source["question"] = 4
        XCTAssertEqual(event.details?["question"] as? Int, 3)
    }

    func test_fromJSONReturnsNilWhenRequiredKeyMissing() {
        let full: [String: Any] = ["userId": "u", "category": "c", "action": "a",
                                   "timestamp": "2026-10-07T08:00:00.000Z"]
        XCTAssertNotNil(MobyBeaconEvent(jsonObject: full))
        for key in ["userId", "category", "action", "timestamp"] {
            var json = full
            json.removeValue(forKey: key)
            XCTAssertNil(MobyBeaconEvent(jsonObject: json), "missing \(key)")
            json[key] = 5
            XCTAssertNil(MobyBeaconEvent(jsonObject: json), "non-string \(key)")
        }
        var badDate = full
        badDate["timestamp"] = "not a date"
        XCTAssertNil(MobyBeaconEvent(jsonObject: badDate))
        var badDetails = full
        badDetails["details"] = "oops"
        XCTAssertNil(MobyBeaconEvent(jsonObject: badDetails))
        var nullDetails = full
        nullDetails["details"] = NSNull()
        XCTAssertNotNil(MobyBeaconEvent(jsonObject: nullDetails))
    }

    func test_dateParsesWithAndWithoutFractionalSeconds() throws {
        let withFraction = try XCTUnwrap(ISO8601.date(from: "2026-10-07T12:00:00.250Z"))
        let without = try XCTUnwrap(ISO8601.date(from: "2026-10-07T12:00:00Z"))
        XCTAssertEqual(withFraction.timeIntervalSince(without), 0.25, accuracy: 0.001)
        XCTAssertEqual(ISO8601.string(from: without), "2026-10-07T12:00:00.000Z")
        XCTAssertNil(ISO8601.date(from: "garbage"))
    }
}
