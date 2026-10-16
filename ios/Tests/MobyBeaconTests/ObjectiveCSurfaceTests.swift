import Foundation
import XCTest
@testable import MobyBeacon

/// Pins the Objective-C selectors the app calls and the queue its callbacks
/// arrive on.
final class ObjectiveCSurfaceTests: XCTestCase {
    private var createdQueueDirectory: URL?

    override func setUpWithError() throws {
        let support = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let queueDirectory = support.appendingPathComponent("moby_beacon")
        // Only clean up a directory this test creates.
        createdQueueDirectory = FileManager.default.fileExists(atPath: queueDirectory.path) ? nil : queueDirectory
    }

    /// The real `start(config:)` loads and rewrites `queue.json`, so it must
    /// not run against a directory that already holds someone's queue.
    private func skipIfQueueDirectoryExists() throws {
        try XCTSkipIf(
            createdQueueDirectory == nil,
            "moby_beacon/ already exists in Application Support; not touching it")
    }

    override func tearDown() {
        MobyBeacon.resetLiveInstanceForTesting()
        if let createdQueueDirectory { try? FileManager.default.removeItem(at: createdQueueDirectory) }
        super.tearDown()
    }

    func test_objectiveCSelectorsExist() {
        XCTAssertTrue(MobyBeacon.responds(to: NSSelectorFromString("startWithConfig:error:")))
        for sel in [
            "track:action:details:",
            "track:action:details:userId:timestamp:",
            "flushWithCompletion:",
            "disposeWithCompletion:",
        ] {
            XCTAssertTrue(MobyBeacon.instancesRespond(to: NSSelectorFromString(sel)), sel)
        }
        XCTAssertTrue(
            MobyBeaconConfig.instancesRespond(to: NSSelectorFromString("initWithEndpoint:apiKey:userId:error:")))
        // The async wrappers are @nonobjc.
        XCTAssertFalse(MobyBeacon.instancesRespond(to: NSSelectorFromString("flushWithCompletionHandler:")))
        XCTAssertFalse(MobyBeacon.instancesRespond(to: NSSelectorFromString("disposeWithCompletionHandler:")))
    }

    func test_setupErrorBridgesToNSErrorWithMessage() {
        let error = MobyBeaconSetupError.invalidEndpoint("x") as NSError
        XCTAssertFalse(error.localizedDescription.isEmpty)
        XCTAssertTrue(error.localizedDescription.contains("endpoint"), error.localizedDescription)
    }

    func test_setupErrorsBridgeWithAStableDomainAndCodes() {
        let cases: [(MobyBeaconSetupError, MobyBeaconSetupErrorCode, Int)] = [
            (.invalidEndpoint("x"), .invalidEndpoint, 1),
            (.emptyAPIKey, .emptyAPIKey, 2),
            (.emptyUserId, .emptyUserId, 3),
            (.userIdTooLong, .userIdTooLong, 4),
            (.userIdContainsNUL, .userIdContainsNUL, 5),
            (.nonPositiveFlushInterval, .nonPositiveFlushInterval, 6),
            (.batchSizeBelowOne, .batchSizeBelowOne, 7),
            (.maxQueueSizeBelowOne, .maxQueueSizeBelowOne, 8),
            (.alreadyRunning, .alreadyRunning, 9),
            (.storageUnavailable("locked"), .storageUnavailable, 10),
        ]
        XCTAssertEqual(MobyBeaconSetupErrorInfo.domain, "MobyBeacon.SetupError")
        for (error, code, rawValue) in cases {
            let bridged = error as NSError
            XCTAssertEqual(bridged.domain, "MobyBeacon.SetupError", "\(error)")
            XCTAssertEqual(error.code, code, "\(error)")
            XCTAssertEqual(code.rawValue, rawValue, "\(error)")
            XCTAssertEqual(bridged.code, rawValue, "\(error)")
            XCTAssertEqual(bridged.localizedDescription, error.errorDescription, "\(error)")
            XCTAssertFalse(bridged.localizedDescription.isEmpty, "\(error)")
        }
    }

    func test_callbacksDefaultToTheMainQueue() throws {
        try skipIfQueueDirectoryExists()
        let config = try MobyBeaconConfig(
            endpoint: "http://localhost:1",
            apiKey: "key",
            userId: "objc-surface-\(UUID().uuidString)")
        let onErrorThread = expectation(description: "onError delivered")
        let lock = NSLock()
        var errorOnMain: Bool?
        config.onError = { _ in
            lock.lock()
            errorOnMain = Thread.isMainThread
            lock.unlock()
            onErrorThread.fulfill()
        }

        let beacon = try MobyBeacon.start(config: config)
        beacon.track("", "")  // empty category: a validation error
        wait(for: [onErrorThread], timeout: 1)
        lock.lock()
        XCTAssertEqual(errorOnMain, true)
        lock.unlock()

        let disposed = expectation(description: "dispose completed")
        var completionOnMain: Bool?
        beacon.dispose {
            completionOnMain = Thread.isMainThread
            disposed.fulfill()
        }
        wait(for: [disposed], timeout: 1)
        XCTAssertEqual(completionOnMain, true)
    }
}
