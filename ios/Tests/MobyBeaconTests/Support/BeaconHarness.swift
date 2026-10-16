import Foundation
import XCTest
@testable import MobyBeacon

/// A 201 accepting the batch with no per-event errors.
func accepted() -> HTTPResponse {
    jsonResponse(["accepted": 1, "errors": [Any]()], status: 201)
}

/// Port of the `main()` preamble of `moby_beacon_test.dart`: a per-test
/// virtual-time scheduler, in-memory storage and a mock HTTP client that
/// records every request. Every beacon started through `start(...)` is
/// disposed in `tearDown`.
class BeaconHarness: XCTestCase {
    var scheduler: TestScheduler!
    var storage: MemoryQueueStorage!
    var mock: MockHTTPClient!
    /// The `events` array of each request, in order.
    var requests: [[[String: Any]]] = []
    /// The body size of each request, in bytes.
    var requestBytes: [Int] = []
    var errors: [MobyBeaconError] = []
    /// Answers each request; replace it to fail or hold sends.
    var respond: (HTTPRequest, @escaping (Result<HTTPResponse, Error>) -> Void) -> Void = { _, _ in }

    private var beacons: [MobyBeacon] = []

    override func setUp() {
        super.setUp()
        scheduler = TestScheduler()
        storage = MemoryQueueStorage()
        requests = []
        requestBytes = []
        errors = []
        respond = { _, done in done(.success(accepted())) }
        mock = MockHTTPClient()
        mock.handler = { [unowned self] request, done in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            self.requests.append(body?["events"] as? [[String: Any]] ?? [])
            self.requestBytes.append(request.body.count)
            self.respond(request, done)
        }
    }

    override func tearDown() {
        for beacon in beacons {
            beacon.dispose(completion: nil)
        }
        beacons = []
        scheduler.runUntilIdle()
        // A dispose held open by a pending send never finishes.
        MobyBeacon.resetLiveInstanceForTesting()
        scheduler = nil
        storage = nil
        mock = nil
        super.tearDown()
    }

    /// Flutter's `create`: a beacon over `storage` and the mock client, with no
    /// jitter and callbacks delivered synchronously on the scheduler.
    func makeBeacon(
        batchSize: Int = 10,
        maxQueueSize: Int = 100,
        onError: ((MobyBeaconError) -> Void)? = nil,
        transport: Transport? = nil,
        lifecycle: LifecycleSource? = nil
    ) throws -> MobyBeacon {
        let config = try MobyBeaconConfig(endpoint: "https://beacon.test", apiKey: "key-123", userId: "user-1")
        config.batchSize = batchSize
        config.maxQueueSize = maxQueueSize
        config.onError = onError ?? { [unowned self] in self.errors.append($0) }
        return try MobyBeacon.start(
            config: config,
            store: EventStore(storage: storage, maxSize: maxQueueSize, scheduler: scheduler),
            transport: transport ?? Transport(endpoint: "https://beacon.test", apiKey: "key-123", client: mock),
            scheduler: scheduler,
            random: FixedRandom(0),
            deliverCallback: { $0() },
            lifecycle: lifecycle)
    }

    /// `makeBeacon`, run until idle, and disposed in `tearDown`.
    func start(
        batchSize: Int = 10,
        maxQueueSize: Int = 100,
        onError: ((MobyBeaconError) -> Void)? = nil,
        transport: Transport? = nil,
        lifecycle: LifecycleSource? = nil
    ) throws -> MobyBeacon {
        let beacon = try makeBeacon(
            batchSize: batchSize,
            maxQueueSize: maxQueueSize,
            onError: onError,
            transport: transport,
            lifecycle: lifecycle)
        scheduler.runUntilIdle()
        beacons.append(beacon)
        return beacon
    }

    func actionsOf(_ events: [[String: Any]]) -> [String] {
        events.map { $0["action"] as? String ?? "<missing action>" }
    }

    func sentActions(_ requestIndex: Int, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard requestIndex < requests.count else {
            XCTFail("only \(requests.count) request(s) sent", file: file, line: line)
            return []
        }
        return actionsOf(requests[requestIndex])
    }
}
