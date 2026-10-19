import XCTest
@testable import MobyBeacon

final class ValidationTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_791_331_200)

    private func event(userId: String = "user-1", category: String = "screen", action: String = "view",
                       details: [String: Any]? = nil) -> MobyBeaconEvent {
        MobyBeaconEvent(userId: userId, category: category, action: action, timestamp: fixedDate, details: details)
    }

    private func assertThrowsMessage(_ message: String, _ event: MobyBeaconEvent,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try validateEvent(event), file: file, line: line) { error in
            XCTAssertEqual(error as? ValidationError, ValidationError(message: message), file: file, line: line)
        }
    }

    private func withField(_ field: String, _ value: String) -> MobyBeaconEvent {
        event(userId: field == "userId" ? value : "user-1",
              category: field == "category" ? value : "screen",
              action: field == "action" ? value : "view")
    }

    func test_acceptsAMinimalEvent() {
        XCTAssertNoThrow(try validateEvent(event()))
    }

    func test_acceptsPrimitiveDetails() {
        XCTAssertNoThrow(try validateEvent(event(details: [
            "s": "text", "i": 3, "d": 1.5, "b": true, "n": NSNull(),
        ])))
    }

    func test_rejectsEmptyFields() {
        for field in ["userId", "category", "action"] {
            assertThrowsMessage("\(field) is required and must be a non-empty string", withField(field, ""))
        }
    }

    func test_rejectsFieldsOver255Characters() {
        for field in ["userId", "category", "action"] {
            assertThrowsMessage("\(field) must be at most 255 characters",
                                withField(field, String(repeating: "x", count: 256)))
        }
    }

    func test_rejectsNestedMapValues() {
        assertThrowsMessage("details.nested must be a string, number, boolean, or null — not a nested object or array",
                            event(details: ["nested": ["a": 1]]))
    }

    func test_rejectsListValues() {
        assertThrowsMessage("details.list must be a string, number, boolean, or null — not a nested object or array",
                            event(details: ["list": [1, 2]]))
    }

    func test_rejectsMoreThan50Keys() {
        var details: [String: Any] = [:]
        for i in 0..<51 { details["k\(i)"] = i }
        assertThrowsMessage("details must have at most 50 keys", event(details: details))
    }

    func test_rejectsKeysOver255Characters() {
        assertThrowsMessage("details key must be at most 255 characters",
                            event(details: [String(repeating: "k", count: 256): 1]))
    }

    func test_rejectsStringValuesOver1000Characters() {
        assertThrowsMessage("details string values must be at most 1000 characters",
                            event(details: ["s": String(repeating: "x", count: 1001)]))
    }

    func test_rejectsNaNAndInfinity() {
        assertThrowsMessage("details.n must be a finite number", event(details: ["n": Double.nan]))
        assertThrowsMessage("details.n must be a finite number", event(details: ["n": Double.infinity]))
    }

    func test_rejectsNULCharactersInRequiredStrings() {
        assertThrowsMessage("category must not contain NUL characters", event(category: "a\u{0}b"))
    }

    func test_rejectsNULCharactersInDetailsKeysAndStringValues() {
        assertThrowsMessage("details keys must not contain NUL characters", event(details: ["k\u{0}": 1]))
        assertThrowsMessage("details.s must not contain NUL characters", event(details: ["s": "a\u{0}"]))
    }

    func test_acceptsValuesExactlyAtTheLimits() {
        var details: [String: Any] = [:]
        for i in 0..<49 { details["k\(i)"] = i }
        details[String(repeating: "k", count: 255)] = String(repeating: "x", count: 1000)
        XCTAssertNoThrow(try validateEvent(event(category: String(repeating: "x", count: 255), details: details)))
    }

    func test_rejectsAWhitespaceOnlyUserId() {
        assertThrowsMessage("userId must not be blank", event(userId: " \t\n"))
    }

    // MARK: sanitizeString

    /// Swift's String views repair lone surrogates on read, so equality alone
    /// cannot tell a sanitized string from a raw one. Also require that the
    /// result encodes as JSON, which the raw bridged string does not.
    private func assertSanitizes(_ units: [UInt16], to expected: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let sanitized = sanitizeString(utf16String(units))
        XCTAssertEqual(sanitized, expected, file: file, line: line)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: [sanitized]), file: file, line: line)
    }

    func test_replacesALoneHighSurrogate() {
        assertSanitizes([0x61, 0xD83D, 0x62], to: "a\u{FFFD}b")
    }

    func test_replacesALoneLowSurrogate() {
        assertSanitizes([0x61, 0xDE00, 0x62], to: "a\u{FFFD}b")
    }

    func test_replacesAHighSurrogateAtTheEndOfTheString() {
        // "I feel " followed by the first half of U+1F600.
        let units = Array("I feel ".utf16) + [0xD83D]
        assertSanitizes(units, to: "I feel \u{FFFD}")
    }

    func test_replacesEachHalfOfAReversedPair() {
        assertSanitizes([0xDE00, 0xD83D], to: "\u{FFFD}\u{FFFD}")
    }

    func test_keepsValidPairsAndOtherTextUnchanged() {
        let text = "plain, accents é, emoji \u{1F600}\u{1F44D}"
        XCTAssertEqual(sanitizeString(text), text)
        XCTAssertEqual(sanitizeString(""), "")
    }

    // MARK: sanitizeEvent

    func test_cleansRequiredStringsDetailsKeysAndStringValues() {
        let cleaned = sanitizeEvent(MobyBeaconEvent(
            userId: utf16String([0x75, 0xD83D]),
            category: utf16String([0x63, 0xDE00]),
            action: utf16String([0xD83D, 0x61]),
            timestamp: fixedDate,
            details: [utf16String([0x6B, 0xD83D]): utf16String([0x76, 0xDE00]), "n": 1, "b": true, "z": NSNull()]))

        XCTAssertEqual(cleaned.userId, "u\u{FFFD}")
        XCTAssertEqual(cleaned.category, "c\u{FFFD}")
        XCTAssertEqual(cleaned.action, "\u{FFFD}a")
        XCTAssertEqual(cleaned.timestamp, fixedDate)
        let details = cleaned.details
        XCTAssertEqual(details?.count, 4)
        XCTAssertEqual(details?["k\u{FFFD}"] as? String, "v\u{FFFD}")
        XCTAssertEqual(details?["n"] as? Int, 1)
        XCTAssertEqual(details?["b"] as? Bool, true)
        XCTAssertTrue(details?["z"] is NSNull)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: cleaned.toJSONObject()))
    }

    func test_copiesDetailsSoLaterChangesDoNotLeakIn() {
        var details: [String: Any] = ["a": 1]
        let cleaned = sanitizeEvent(event(details: details))
        details["a"] = 2
        details["b"] = 1

        XCTAssertEqual(cleaned.details?.count, 1)
        XCTAssertEqual(cleaned.details?["a"] as? Int, 1)
    }

    func test_aSelfContainingArrayIsCopiedWithoutRecursingAndRejected() {
        let loop = NSMutableArray(array: ["x"])
        loop.add(loop)
        defer { loop.removeAllObjects() } // Break the cycle so the array is freed.

        let cleaned = sanitizeEvent(event(details: ["loop": loop]))

        XCTAssertEqual((cleaned.details?["loop"] as? [Any])?.count, 2)
        assertThrowsMessage("details.loop must be a string, number, boolean, or null — not a nested object or array",
                            cleaned)
    }

    func test_aNilSwiftOptionalBecomesNull() throws {
        let note: String? = nil
        let present: String? = "x"
        let cleaned = sanitizeEvent(event(details: ["note": note as Any, "present": present as Any]))

        XCTAssertTrue(cleaned.details?["note"] is NSNull)
        XCTAssertEqual(cleaned.details?["present"] as? String, "x")
        XCTAssertNoThrow(try validateEvent(cleaned))
        let data = try JSONSerialization.data(withJSONObject: cleaned.toJSONObject())
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""note":null"#))
    }

    func test_keepsNullDetails() {
        XCTAssertNil(sanitizeEvent(event()).details)
    }

    // MARK: Swift-native values

    func test_acceptsSwiftNativePrimitiveDetailValues() {
        let event = MobyBeaconEvent(userId: "u", category: "c", action: "a", timestamp: Date(),
                                    details: ["b": true, "i": 1, "d": 1.5, "n": NSNull(), "s": "x"])
        XCTAssertNoThrow(try validateEvent(event))
        let data = try! JSONSerialization.data(withJSONObject: event.toJSONObject())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"b\":true"))   // a Bool stays a JSON boolean, not 1
    }

    func test_rejectsDateAndDataDetailValues() {
        let message = "must be a string, number, boolean, or null"
        for (key, value) in [("when", Date() as Any), ("blob", Data([1, 2, 3]) as Any)] {
            XCTAssertThrowsError(try validateEvent(event(details: [key: value]))) { error in
                let actual = (error as? ValidationError)?.message ?? ""
                XCTAssertTrue(actual.hasPrefix("details.\(key) \(message)"), actual)
            }
        }
    }

    func test_sanitizedBridgedStringEncodesAsJSON() {
        let raw = utf16String([0x49, 0xD83D])
        // Negative control: the unsanitized bridged string cannot be encoded.
        XCTAssertThrowsError(try JSONSerialization.data(withJSONObject: [raw]))
        let sanitized = sanitizeString(raw)
        XCTAssertEqual(sanitized, "I\u{FFFD}")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["s": sanitized]))
    }

    func test_isValidDetailValueClassifiesPrimitives() {
        XCTAssertTrue(isValidDetailValue(nil))
        XCTAssertTrue(isValidDetailValue(NSNull()))
        XCTAssertTrue(isValidDetailValue("x"))
        XCTAssertTrue(isValidDetailValue(NSString(string: "x")))
        XCTAssertTrue(isValidDetailValue(true))
        XCTAssertTrue(isValidDetailValue(3))
        XCTAssertTrue(isValidDetailValue(1.5))
        XCTAssertFalse(isValidDetailValue(Double.nan))
        XCTAssertFalse(isValidDetailValue(Double.infinity))
        XCTAssertFalse(isValidDetailValue(Date()))
        XCTAssertFalse(isValidDetailValue([1, 2]))
    }
}
