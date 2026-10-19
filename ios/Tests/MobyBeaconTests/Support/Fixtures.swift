import Foundation
import XCTest
@testable import MobyBeacon

/// A stored event as it appears in a queue file written by an earlier run.
func storedEvent(_ action: String) -> [String: Any] {
    [
        "userId": "user-1",
        "category": "screen",
        "action": action,
        "timestamp": "2026-10-06T09:00:00.000Z",
    ]
}

/// Builds a version 1 queue file holding `events`.
func v1(_ events: [Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["v": 1, "events": events], options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// Actions of the events in a stored version 1 queue file.
func storedActions(_ contents: String?, file: StaticString = #filePath, line: UInt = #line) -> [String] {
    guard let contents,
          let stored = try? JSONSerialization.jsonObject(with: Data(contents.utf8)) as? [String: Any],
          let events = stored["events"] as? [[String: Any]]
    else {
        XCTFail("not a queue file: \(String(describing: contents))", file: file, line: line)
        return []
    }
    XCTAssertEqual(stored["v"] as? Int, 1, file: file, line: line)
    return events.map { $0["action"] as? String ?? "<missing action>" }
}

/// A valid event with `action`, timestamped 2026-10-07T00:00:00Z.
func event(_ action: String, details: [String: Any]? = nil) -> MobyBeaconEvent {
    MobyBeaconEvent(
        userId: "user-1",
        category: "test",
        action: action,
        timestamp: ISO8601.date(from: "2026-10-07T00:00:00.000Z")!,
        details: details)
}
