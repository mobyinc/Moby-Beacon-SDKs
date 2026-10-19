import XCTest
@testable import MobyBeacon

final class ConfigTests: XCTestCase {
    private func config(
        endpoint: String = "https://beacon.test",
        apiKey: String = "key-123",
        userId: String = "user-1"
    ) throws -> MobyBeaconConfig {
        try MobyBeaconConfig(endpoint: endpoint, apiKey: apiKey, userId: userId)
    }

    private func assertThrows(
        _ expected: MobyBeaconSetupError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? MobyBeaconSetupError, expected, file: file, line: line)
        }
    }

    func test_appliesDefaults() throws {
        let c = try MobyBeaconConfig(endpoint: "https://beacon.test", apiKey: "k", userId: "u")
        XCTAssertEqual(c.flushInterval, 5)
        XCTAssertEqual(c.batchSize, 10)
        XCTAssertEqual(c.maxQueueSize, 10_000)
        XCTAssertNil(c.onError)
    }

    func test_stripsATrailingSlashFromEndpoint() throws {
        XCTAssertEqual(try config(endpoint: "https://beacon.test/").endpoint, "https://beacon.test")
    }

    func test_rejectsEmptyEndpointApiKeyAndUserId() {
        assertThrows(.invalidEndpoint("")) { try config(endpoint: "") }
        assertThrows(.invalidEndpoint("/")) { try config(endpoint: "/") }
        assertThrows(.emptyAPIKey) { try config(apiKey: "") }
        assertThrows(.emptyUserId) { try config(userId: "") }
    }

    func test_rejectsNonPositiveFlushIntervalBatchSizeAndMaxQueueSize() throws {
        let c = try MobyBeaconConfig(endpoint: "https://beacon.test", apiKey: "k", userId: "u")
        XCTAssertNoThrow(try c.validatedSettings())

        c.flushInterval = 0
        XCTAssertThrowsError(try c.validatedSettings()) {
            XCTAssertEqual($0 as? MobyBeaconSetupError, .nonPositiveFlushInterval)
        }
        c.flushInterval = 5

        c.batchSize = 0
        XCTAssertThrowsError(try c.validatedSettings()) {
            XCTAssertEqual($0 as? MobyBeaconSetupError, .batchSizeBelowOne)
        }
        c.batchSize = 10

        c.maxQueueSize = 0
        XCTAssertThrowsError(try c.validatedSettings()) {
            XCTAssertEqual($0 as? MobyBeaconSetupError, .maxQueueSizeBelowOne)
        }
    }

    func test_validatedSettingsSnapshotsTheConfig() throws {
        let c = try MobyBeaconConfig(endpoint: "https://beacon.test/", apiKey: "k", userId: "u")
        c.flushInterval = 2
        c.batchSize = 3
        c.maxQueueSize = 4
        let s = try c.validatedSettings()
        XCTAssertEqual(s.endpoint, "https://beacon.test")
        XCTAssertEqual(s.apiKey, "k")
        XCTAssertEqual(s.userId, "u")
        XCTAssertEqual(s.flushInterval, 2)
        XCTAssertEqual(s.batchSize, 3)
        XCTAssertEqual(s.maxQueueSize, 4)
    }

    func test_stripsAllTrailingSlashesAndKeepsAnyPath() throws {
        XCTAssertEqual(try config(endpoint: "https://beacon.test//").endpoint, "https://beacon.test")
        XCTAssertEqual(try config(endpoint: "https://beacon.test/api/").endpoint, "https://beacon.test/api")
        XCTAssertEqual(try config(endpoint: "https://beacon.test/api///").endpoint, "https://beacon.test/api")
    }

    func test_rejectsEndpointsThatAreNotAbsoluteHttpsURLs() {
        for endpoint in ["beacon.test", "localhost:3011", "ftp://beacon.test", "https://", ""] {
            assertThrows(.invalidEndpoint(endpoint)) { try config(endpoint: endpoint) }
        }
    }

    func test_rejectsEndpointsWithAQueryFragmentOrWhitespace() {
        for endpoint in ["https://beacon.test?x=1", "https://beacon.test/api?", "https://beacon.test#frag",
                         "https://beacon.test ", "https://beacon.test\n", "https://bea con.test"] {
            assertThrows(.invalidEndpoint(endpoint)) { try config(endpoint: endpoint) }
        }
    }

    func test_rejectsAnApiKeyWithControlCharacters() throws {
        for apiKey in ["key\n", "key\r\n", "\tkey", "ke\u{0}y", "key\u{7F}"] {
            assertThrows(.apiKeyContainsControlCharacters) { try config(apiKey: apiKey) }
        }
        XCTAssertEqual(try config(apiKey: "key with spaces").apiKey, "key with spaces")
    }

    func test_rejectsWhitespaceOnlyApiKeyAndUserId() {
        assertThrows(.emptyAPIKey) { try config(apiKey: "  ") }
        assertThrows(.emptyUserId) { try config(userId: "\n") }
    }

    func test_rejectsAUserIdTheAPIWouldNotAccept() throws {
        assertThrows(.userIdTooLong) { try config(userId: String(repeating: "x", count: 256)) }
        assertThrows(.userIdContainsNUL) { try config(userId: "a\u{0}b") }
        XCTAssertEqual(try config(userId: String(repeating: "x", count: 255)).userId.count, 255)
    }

    func test_errorDescriptionNamesTypeAndMessage() {
        let error = MobyBeaconError(type: .network, message: "offline", events: [], errors: nil, willRetry: true)
        XCTAssertEqual(error.description, "MobyBeaconError(network): offline")
        for (type, name) in [(MobyBeaconErrorType.server, "server"), (.auth, "auth"), (.validation, "validation")] {
            XCTAssertEqual(
                MobyBeaconError(type: type, message: "m", events: [], errors: nil, willRetry: false).description,
                "MobyBeaconError(\(name)): m")
        }
    }

    func test_errorTypeInterpolatesAsItsName() {
        XCTAssertEqual(["\(MobyBeaconErrorType.network)", "\(MobyBeaconErrorType.server)",
                        "\(MobyBeaconErrorType.auth)", "\(MobyBeaconErrorType.validation)"],
                       ["network", "server", "auth", "validation"])
    }

    func test_setupErrorsHavePlainEnglishDescriptions() {
        XCTAssertEqual(
            MobyBeaconSetupError.invalidEndpoint("x").errorDescription,
            "endpoint must be an absolute http(s) URL: x")
        XCTAssertEqual(MobyBeaconSetupError.emptyAPIKey.errorDescription, "apiKey must not be empty")
        XCTAssertEqual(
            MobyBeaconSetupError.apiKeyContainsControlCharacters.errorDescription,
            "apiKey must not contain control characters")
    }
}
