import Foundation
@testable import MobyBeacon

/// In-memory `QueueStorage` for tests. Completes synchronously on the calling
/// thread, except for writes held back by `holdWrites`.
final class MemoryQueueStorage: QueueStorage {
    init(_ contents: String? = nil) {
        self.contents = contents
    }

    var contents: String?

    /// Number of write attempts, including ones that failed.
    var writeCount = 0
    var quarantined = false

    /// When set, `read` fails with it (simulates storage that is unavailable).
    var readError: Error?

    /// When set, `write` fails with it once the write is allowed to complete.
    var writeError: Error?

    /// While true, `write` calls are held in flight: counted but not stored or
    /// completed until `releaseHeldWrites()`, which also sets this back to
    /// false so later writes pass straight through (like Dart's completed gate).
    var holdWrites = false

    private var heldWrites: [(contents: String, completion: (Result<Void, Error>) -> Void)] = []

    func read(_ completion: @escaping (Result<String?, Error>) -> Void) {
        if let readError {
            completion(.failure(readError))
        } else {
            completion(.success(contents))
        }
    }

    func write(_ contents: String, _ completion: @escaping (Result<Void, Error>) -> Void) {
        writeCount += 1
        if holdWrites {
            heldWrites.append((contents, completion))
        } else {
            complete(contents, completion)
        }
    }

    func quarantine(_ completion: @escaping (Result<Void, Error>) -> Void) {
        quarantined = true
        contents = nil
        completion(.success(()))
    }

    /// Stops holding writes and completes every held write in order, applying
    /// `writeError` if set.
    func releaseHeldWrites() {
        holdWrites = false
        let held = heldWrites
        heldWrites = []
        for write in held {
            complete(write.contents, write.completion)
        }
    }

    private func complete(_ contents: String, _ completion: (Result<Void, Error>) -> Void) {
        if let writeError {
            completion(.failure(writeError))
        } else {
            self.contents = contents
            completion(.success(()))
        }
    }
}
