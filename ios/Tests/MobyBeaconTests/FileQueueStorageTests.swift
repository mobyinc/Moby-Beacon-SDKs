import XCTest
@testable import MobyBeacon

final class FileQueueStorageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moby_beacon_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions and flags a test may have changed, so deletion succeeds.
        try? FileManager.default.setAttributes(
            [.immutable: false], ofItemAtPath: dir.appendingPathComponent("queue.json").path
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: file(name).path)
    }

    private func read(
        _ storage: FileQueueStorage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<String?, Error> {
        let done = expectation(description: "read")
        var result: Result<String?, Error>?
        storage.read {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        guard let result else {
            XCTFail("read did not complete", file: file, line: line)
            return .success(nil)
        }
        return result
    }

    private func write(_ storage: FileQueueStorage, _ contents: String) -> Result<Void, Error> {
        let done = expectation(description: "write")
        var result: Result<Void, Error> = .success(())
        storage.write(contents) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        return result
    }

    private func quarantine(_ storage: FileQueueStorage) -> Result<Void, Error> {
        let done = expectation(description: "quarantine")
        var result: Result<Void, Error> = .success(())
        storage.quarantine {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        return result
    }

    func test_readReturnsNilWhenNoFileExists() throws {
        XCTAssertNil(try read(FileQueueStorage(directory: dir)).get())
    }

    func test_writeThenReadRoundTripsAndLeavesNoTempFile() throws {
        let storage = FileQueueStorage(directory: dir)
        try write(storage, "[1,2,3]").get()

        XCTAssertEqual(try read(storage).get(), "[1,2,3]")
        XCTAssertFalse(exists("queue.json.tmp"))
    }

    func test_writeCreatesAMissingDirectory() throws {
        let nested = dir.appendingPathComponent("nested/moby_beacon", isDirectory: true)
        try write(FileQueueStorage(directory: nested), "[]").get()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nested.appendingPathComponent("queue.json").path)
        )
    }

    func test_quarantineMovesTheQueueAside() throws {
        let storage = FileQueueStorage(directory: dir)
        try write(storage, "{not json").get()
        try quarantine(storage).get()

        XCTAssertNil(try read(storage).get())
        XCTAssertEqual(
            try String(contentsOf: file("queue.json.corrupt"), encoding: .utf8),
            "{not json"
        )
    }

    func test_aStrayTempFileIsIgnoredByReadAndReplacedByWrite() throws {
        try "partial".write(to: file("queue.json.tmp"), atomically: true, encoding: .utf8)
        let storage = FileQueueStorage(directory: dir)
        XCTAssertNil(try read(storage).get())

        try write(storage, "complete").get()
        XCTAssertEqual(try read(storage).get(), "complete")
        XCTAssertFalse(exists("queue.json.tmp"))
    }

    func test_aFailedWriteRemovesItsTempFileAndRethrows() throws {
        // An immutable queue.json makes replacing it fail after the temp file
        // has already been written.
        let storage = FileQueueStorage(directory: dir)
        try write(storage, "old").get()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: storage.fileURL.path)

        let result = write(storage, "new")
        let tempExists = exists("queue.json.tmp")
        // Clear the flag before asserting, so a failure cannot leave an
        // undeletable file behind.
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: storage.fileURL.path)

        if case .success = result {
            XCTFail("expected the write to fail")
        }
        XCTAssertFalse(tempExists)
        XCTAssertEqual(try read(storage).get(), "old")
    }

    func test_invalidUTF8ReadsAsTextAndIsQuarantinedByLoad() throws {
        // The quarantine half lives with the EventStore tests.
        try Data([0xff, 0xfe, 0x7b, 0x80]).write(to: file("queue.json"))
        let text = try XCTUnwrap(try read(FileQueueStorage(directory: dir)).get())
        XCTAssertTrue(text.contains("\u{FFFD}"))
    }

    func test_readFailsWhenDirectoryIsUnreadable() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses file permissions")
        let storage = FileQueueStorage(directory: dir)
        try write(storage, "[]").get()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)

        switch read(storage) {
        case .success(let contents):
            XCTFail("expected a failure, got .success(\(String(describing: contents)))")
        case .failure:
            break
        }
    }
}
