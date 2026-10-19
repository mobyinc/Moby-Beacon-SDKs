import XCTest
@testable import MobyBeacon

final class EventStoreTests: XCTestCase {
    private var scheduler: TestScheduler!

    override func setUp() {
        super.setUp()
        scheduler = TestScheduler()
    }

    override func tearDown() {
        scheduler = nil
        super.tearDown()
    }

    private func makeStore(_ storage: MemoryQueueStorage = MemoryQueueStorage(), maxSize: Int = 10) -> EventStore {
        EventStore(storage: storage, maxSize: maxSize, scheduler: scheduler)
    }

    /// Loads `store` and runs the scheduler until the load has settled.
    private func load(_ store: EventStore, file: StaticString = #filePath, line: UInt = #line) throws {
        var loaded = false
        try store.load { loaded = true }
        scheduler.runUntilIdle()
        XCTAssertTrue(loaded, "load did not complete", file: file, line: line)
    }

    /// Persists `store` and runs the scheduler until the persist has settled.
    private func persist(_ store: EventStore, file: StaticString = #filePath, line: UInt = #line) {
        var persisted = false
        store.persist { persisted = true }
        scheduler.runUntilIdle()
        XCTAssertTrue(persisted, "persist did not complete", file: file, line: line)
    }

    private func actions(_ events: [MobyBeaconEvent]) -> [String] {
        events.map(\.action)
    }

    /// `event` encoded as the store encodes it.
    private func json(_ event: MobyBeaconEvent) -> String {
        let data = try! JSONSerialization.data(withJSONObject: event.toJSONObject(), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: EventStore

    func test_behavesAsAFIFOQueue() throws {
        let store = makeStore()
        try store.add(event("a"))
        try store.add(event("b"))
        try store.add(event("c"))

        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(actions(store.peek(2)), ["a", "b"])
        XCTAssertEqual(store.count, 3, "peek does not remove")

        store.removeFirst(2)
        XCTAssertEqual(actions(store.peek(10)), ["c"])
    }

    func test_addThrowsStateErrorAtMaxSize() throws {
        let store = makeStore(maxSize: 1)
        try store.add(event("a"))
        XCTAssertThrowsError(try store.add(event("b"))) { error in
            XCTAssertEqual(error as? StoreError, .atCapacity)
        }
    }

    func test_persistsAndReloadsEvents() throws {
        let storage = MemoryQueueStorage()
        let store = makeStore(storage)
        try store.add(event("a"))
        try store.add(event("b"))
        persist(store)

        let reloaded = makeStore(storage)
        try load(reloaded)
        XCTAssertEqual(actions(reloaded.peek(10)), ["a", "b"])
    }

    func test_writesTheVersionedFileFormat() throws {
        let storage = MemoryQueueStorage()
        let store = makeStore(storage)
        try store.add(event("a"))
        persist(store)

        XCTAssertEqual(storedActions(storage.contents), ["a"])
    }

    func test_roundTripsEventsWithDetails() throws {
        let storage = MemoryQueueStorage()
        let original = MobyBeaconEvent(
            userId: "user-1",
            category: "test",
            action: "a",
            timestamp: ISO8601.date(from: "2026-10-07T12:30:15.250Z")!,
            details: ["s": "text", "i": 3, "d": 1.5, "b": true, "n": NSNull()])
        let store = makeStore(storage)
        try store.add(original)
        persist(store)

        let reloaded = makeStore(storage)
        try load(reloaded)
        let loaded = reloaded.peek(1)
        XCTAssertEqual(loaded.count, 1)
        // Compared as JSON text so a boolean turning into a number would show.
        XCTAssertEqual(loaded.first.map(json), json(original))
    }

    func test_loadWithNothingStoredStartsEmpty() throws {
        let storage = MemoryQueueStorage()
        let store = makeStore(storage)
        try load(store)
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(storage.quarantined)
    }

    func test_loadQuarantinesAnUnparseableQueueAndStartsEmpty() throws {
        let storage = MemoryQueueStorage("{not json")
        var messages: [String] = []
        let store = makeStore(storage)
        store.onDiscarded = { messages.append($0) }

        try load(store)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(storage.quarantined)
        XCTAssertEqual(messages, ["Persisted event queue was unreadable and has been discarded"])
    }

    private func assertLoadQuarantinesWrongShapeContent(
        _ contents: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let storage = MemoryQueueStorage(contents)
        var messages: [String] = []
        let store = makeStore(storage)
        store.onDiscarded = { messages.append($0) }

        try load(store, file: file, line: line)
        XCTAssertEqual(store.count, 0, file: file, line: line)
        XCTAssertTrue(storage.quarantined, file: file, line: line)
        XCTAssertEqual(messages.count, 1, file: file, line: line)
    }

    func test_loadQuarantinesWrongShapeContentEmptyObject() throws {
        try assertLoadQuarantinesWrongShapeContent("{}")
    }

    func test_loadQuarantinesWrongShapeContentEmptyArray() throws {
        try assertLoadQuarantinesWrongShapeContent("[]")
    }

    func test_loadQuarantinesWrongShapeContentVersion2() throws {
        try assertLoadQuarantinesWrongShapeContent(#"{"v":2,"events":[]}"#)
    }

    func test_loadSkipsBadEntriesKeepsGoodOnesAndRewritesTheFile() throws {
        let storage = MemoryQueueStorage(v1([
            event("a").toJSONObject(),
            ["bogus": 1],
            event("b").toJSONObject(),
        ]))
        var messages: [String] = []
        let store = makeStore(storage)
        store.onDiscarded = { messages.append($0) }

        try load(store)
        XCTAssertEqual(actions(store.peek(10)), ["a", "b"])
        XCTAssertFalse(storage.quarantined)
        XCTAssertEqual(messages, ["1 persisted event(s) were unreadable and have been discarded"])

        persist(store)
        XCTAssertEqual(storedActions(storage.contents), ["a", "b"])
    }

    func test_loadSkipsStoredEntriesThatFailValidation() throws {
        var nested = event("nested").toJSONObject()
        nested["details"] = ["x": ["y": 1]]
        var blank = event("blank").toJSONObject()
        blank["category"] = ""
        let storage = MemoryQueueStorage(v1([
            event("a").toJSONObject(),
            nested,
            blank,
            event("b").toJSONObject(),
        ]))
        var messages: [String] = []
        let store = makeStore(storage)
        store.onDiscarded = { messages.append($0) }

        try load(store)
        XCTAssertEqual(actions(store.peek(10)), ["a", "b"])
        XCTAssertEqual(messages, ["2 persisted event(s) were unreadable and have been discarded"])
    }

    func test_loadReplacesLoneSurrogatesInStoredEntries() throws {
        // The file text Dart's `v1([event('a\uD83D').toJson()])` produces: a
        // lone surrogate can only reach the file as a JSON escape.
        let contents = v1([event("a").toJSONObject()])
            .replacingOccurrences(of: #""action":"a""#, with: #""action":"a\ud83d""#)
        XCTAssertTrue(contents.contains(#"\ud83d"#))
        let store = makeStore(MemoryQueueStorage(contents))

        try load(store)
        XCTAssertEqual(actions(store.peek(10)), ["a\u{FFFD}"])
    }

    /// Guards the lone-surrogate repair above: escaped pairs and an escaped
    /// backslash followed by `ud83d` are left as they are.
    func test_loadKeepsSurrogatePairEscapesAndEscapedBackslashes() throws {
        let contents = v1([event("a", details: ["k": #"\ud83d"#]).toJSONObject()])
            .replacingOccurrences(of: #""action":"a""#, with: #""action":"\ud83d\ude00""#)
        XCTAssertTrue(contents.contains(#""action":"\ud83d\ude00""#))
        XCTAssertTrue(contents.contains(#"\\ud83d"#))
        let store = makeStore(MemoryQueueStorage(contents))

        try load(store)
        let loaded = store.peek(10)
        XCTAssertEqual(actions(loaded), ["\u{1F600}"])
        XCTAssertEqual(loaded.first?.details?["k"] as? String, #"\ud83d"#)
    }

    func test_loadKeepsAStoredQueueLargerThanMaxSize() throws {
        let storage = MemoryQueueStorage(v1([
            event("a").toJSONObject(),
            event("b").toJSONObject(),
            event("c").toJSONObject(),
        ]))
        let store = makeStore(storage, maxSize: 2)

        try load(store)
        XCTAssertEqual(store.count, 3)
        XCTAssertThrowsError(try store.add(event("d"))) { error in
            XCTAssertEqual(error as? StoreError, .atCapacity)
        }
    }

    func test_loadThrowsStateErrorWhenCalledTwice() throws {
        let store = makeStore()
        try load(store)
        XCTAssertThrowsError(try store.load {}) { error in
            XCTAssertEqual(error as? StoreMisuse, .loadCalledTwice)
        }
    }

    func test_loadThrowsStateErrorAfterAMutation() throws {
        let store = makeStore()
        try store.add(event("a"))
        XCTAssertThrowsError(try store.load {}) { error in
            XCTAssertEqual(error as? StoreMisuse, .loadAfterMutation)
        }
    }

    func test_coalescesRapidMutationsIntoAtMostTwoWrites() throws {
        let storage = MemoryQueueStorage()
        let store = makeStore(storage, maxSize: 1000)
        for i in 0..<100 {
            try store.add(event("e\(i)"))
        }
        persist(store)

        XCTAssertLessThanOrEqual(storage.writeCount, 2)
        XCTAssertEqual(storedActions(storage.contents).count, 100)
    }

    func test_persistReflectsRemovals() throws {
        let storage = MemoryQueueStorage()
        let store = makeStore(storage)
        try store.add(event("a"))
        try store.add(event("b"))
        store.removeFirst(1)
        persist(store)

        XCTAssertEqual(storedActions(storage.contents), ["b"])
    }

    func test_aMutationDuringAWriteCausesExactlyOneFollowUpWrite() throws {
        let storage = MemoryQueueStorage()
        storage.holdWrites = true
        let store = makeStore(storage)
        try store.add(event("a"))
        scheduler.runUntilIdle()
        XCTAssertEqual(storage.writeCount, 1, "first write is in flight")

        try store.add(event("b"))
        var persisted = false
        store.persist { persisted = true }
        scheduler.runUntilIdle()
        XCTAssertFalse(persisted)
        XCTAssertEqual(storage.writeCount, 1)

        storage.releaseHeldWrites()
        scheduler.runUntilIdle()
        XCTAssertTrue(persisted)
        XCTAssertEqual(storage.writeCount, 2)
        XCTAssertEqual(storedActions(storage.contents), ["a", "b"])
    }

    func test_persistRetriesAFailedWrite() throws {
        let storage = MemoryQueueStorage()
        storage.writeError = CocoaError(.fileWriteOutOfSpace)
        let store = makeStore(storage)
        try store.add(event("a"))
        persist(store)
        XCTAssertNil(storage.contents)

        storage.writeError = nil
        persist(store)
        XCTAssertEqual(storedActions(storage.contents), ["a"])
    }

    func test_addRejectsAnEventThatCannotBeEncodedAsJSON() throws {
        let storage = MemoryQueueStorage()
        let store = makeStore(storage)
        // A Date slipped past validation: JSONSerialization cannot encode it.
        let bad = MobyBeaconEvent(
            userId: "user-1",
            category: "test",
            action: "bad",
            timestamp: ISO8601.date(from: "2026-10-07T00:00:00.000Z")!,
            details: ["x": Date()])

        XCTAssertThrowsError(try store.add(bad)) { error in
            XCTAssertEqual(error as? StoreError, .notEncodable)
        }
        XCTAssertEqual(store.count, 0)

        try store.add(event("a"))
        persist(store)
        XCTAssertGreaterThan(storage.writeCount, 0)
        XCTAssertEqual(storedActions(storage.contents), ["a"])
    }

    func test_anUnreadableStoreIsNotQuarantinedOrOverwritten() throws {
        let storage = MemoryQueueStorage(v1([event("stored").toJSONObject()]))
        storage.readError = CocoaError(.fileReadNoPermission)
        var messages: [String] = []
        let store = makeStore(storage)
        store.onDiscarded = { messages.append($0) }

        try load(store)
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(storage.quarantined)

        try store.add(event("new"))
        persist(store)
        XCTAssertEqual(storage.writeCount, 0)
        XCTAssertEqual(storedActions(storage.contents), ["stored"])

        storage.readError = nil
        persist(store)
        XCTAssertEqual(actions(store.peek(10)), ["new", "stored"])
        XCTAssertEqual(storedActions(storage.contents), ["new", "stored"])
        XCTAssertEqual(messages, [])
    }

    /// The store half of FileQueueStorage's invalid-UTF-8 test: storage hands
    /// back the bytes `[0xFF, 0xFE, 0x7B, 0x80]` decoded with U+FFFD.
    func test_loadQuarantinesTextDecodedFromInvalidUTF8() throws {
        let storage = MemoryQueueStorage(String(decoding: [0xFF, 0xFE, 0x7B, 0x80] as [UInt8], as: UTF8.self))
        var messages: [String] = []
        let store = makeStore(storage)
        store.onDiscarded = { messages.append($0) }

        try load(store)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(storage.quarantined)
    }

    func test_eventStoreSurvivesAReloadFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moby_beacon_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scheduler = DispatchScheduler()

        let store = EventStore(storage: FileQueueStorage(directory: dir), maxSize: 10, scheduler: scheduler)
        let persisted = expectation(description: "persist")
        scheduler.queue.async {
            do {
                try store.add(event("a"))
            } catch {
                XCTFail("add failed: \(error)")
            }
            store.persist { persisted.fulfill() }
        }
        wait(for: [persisted], timeout: 1)

        let reloaded = EventStore(storage: FileQueueStorage(directory: dir), maxSize: 10, scheduler: scheduler)
        let loaded = expectation(description: "load")
        scheduler.queue.async {
            do {
                try reloaded.load { loaded.fulfill() }
            } catch {
                XCTFail("load failed: \(error)")
            }
        }
        wait(for: [loaded], timeout: 1)
        let reloadedActions = scheduler.queue.sync { actions(reloaded.peek(10)) }
        XCTAssertEqual(reloadedActions, ["a"])
    }

    // MARK: EventStore.peek with maxBytes

    /// UTF-8 size of `e` as the store encodes it.
    private func bytesOf(_ e: MobyBeaconEvent) -> Int {
        json(e).utf8.count
    }

    func test_returnsTheLongestPrefixWhoseEntriesAndCommasFit() throws {
        let store = makeStore()
        try store.add(event("a"))
        try store.add(event("b"))
        try store.add(event("c"))
        let size = bytesOf(event("a"))

        XCTAssertEqual(actions(store.peek(10, maxBytes: 2 * size + 1)), ["a", "b"])
        XCTAssertEqual(actions(store.peek(10, maxBytes: 2 * size)), ["a"], "the comma between entries counts")
        XCTAssertEqual(actions(store.peek(10, maxBytes: 3 * size + 2)), ["a", "b", "c"])
    }

    func test_stillRespectsCount() throws {
        let store = makeStore()
        try store.add(event("a"))
        try store.add(event("b"))

        XCTAssertEqual(actions(store.peek(1, maxBytes: 1 << 20)), ["a"])
    }

    func test_returnsOneEventEvenWhenItExceedsMaxBytes() throws {
        let store = makeStore()
        try store.add(event("a"))
        try store.add(event("b"))

        XCTAssertEqual(actions(store.peek(10, maxBytes: 1)), ["a"])
    }

    func test_returnsNothingFromAnEmptyStore() {
        let store = makeStore()

        XCTAssertEqual(store.peek(10, maxBytes: 1).count, 0)
    }

    func test_measuresUTF8BytesNotStringLength() throws {
        let store = makeStore()
        try store.add(event("üüüü"))
        try store.add(event("üüüü"))
        let chars = json(event("üüüü")).utf16.count

        XCTAssertEqual(store.peek(10, maxBytes: 2 * chars + 1).count, 1)
        XCTAssertEqual(store.peek(10, maxBytes: 2 * bytesOf(event("üüüü")) + 1).count, 2)
    }

    func test_measuresEventsLoadedFromStorage() throws {
        let storage = MemoryQueueStorage(v1([event("a").toJSONObject(), event("b").toJSONObject()]))
        let store = makeStore(storage)
        try load(store)
        let size = bytesOf(event("a"))

        XCTAssertEqual(actions(store.peek(10, maxBytes: 2 * size)), ["a"])
        XCTAssertEqual(actions(store.peek(10, maxBytes: 2 * size + 1)), ["a", "b"])
    }
}
