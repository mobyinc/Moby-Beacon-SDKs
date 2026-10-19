import Foundation

/// Where the serialized event queue is kept between app runs.
///
/// Completions may be called on any thread; the caller re-dispatches onto its
/// own serial context.
protocol QueueStorage: AnyObject {
    /// Delivers the stored queue, `nil` if nothing has been stored, or a
    /// failure if storage is temporarily unavailable (e.g. iOS before first
    /// unlock) and the read should be retried later.
    func read(_ completion: @escaping (Result<String?, Error>) -> Void)

    /// Replaces the stored queue with `contents`.
    func write(_ contents: String, _ completion: @escaping (Result<Void, Error>) -> Void)

    /// Moves an unreadable stored queue aside so it is not loaded again.
    func quarantine(_ completion: @escaping (Result<Void, Error>) -> Void)
}

/// Stores the queue as `queue.json` in `directory`, writing atomically via a
/// temp file that is flushed to disk and then renamed into place.
final class FileQueueStorage: QueueStorage {
    private let directory: URL
    private let ioQueue: DispatchQueue
    /// Touched only on `ioQueue`.
    private var excludedFromBackup = false

    init(directory: URL, ioQueue: DispatchQueue = DispatchQueue(label: "com.mobyinc.beacon.storage")) {
        self.directory = directory
        self.ioQueue = ioQueue
    }

    var fileURL: URL { directory.appendingPathComponent("queue.json") }
    var tempURL: URL { directory.appendingPathComponent("queue.json.tmp") }
    var corruptURL: URL { directory.appendingPathComponent("queue.json.corrupt") }

    func read(_ completion: @escaping (Result<String?, Error>) -> Void) {
        ioQueue.async {
            let data: Data
            do {
                data = try Data(contentsOf: self.fileURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return completion(.success(nil))
            } catch {
                return completion(.failure(error))
            }
            // Malformed bytes become U+FFFD rather than failing here (which
            // would mean "unavailable, try again later"). Damage inside a JSON
            // string just alters that string; only structural damage fails
            // parsing and is treated as corruption.
            completion(.success(String(decoding: data, as: UTF8.self)))
        }
    }

    func write(_ contents: String, _ completion: @escaping (Result<Void, Error>) -> Void) {
        ioQueue.async {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
                self.excludeFromBackup()
                try self.writeSynchronized(Data(contents.utf8), to: self.tempURL)
                if fileManager.fileExists(atPath: self.fileURL.path) {
                    _ = try fileManager.replaceItemAt(self.fileURL, withItemAt: self.tempURL)
                } else {
                    try fileManager.moveItem(at: self.tempURL, to: self.fileURL)
                }
                completion(.success(()))
            } catch {
                // Best effort; the next write replaces it anyway.
                try? fileManager.removeItem(at: self.tempURL)
                completion(.failure(error))
            }
        }
    }

    /// Keeps queued events out of device and iCloud backups, as Android's
    /// `noBackupFilesDir` does: a queue restored onto another device would
    /// resend events this device has already delivered. The flag is a
    /// directory attribute, so it also covers the temp and quarantine files.
    /// Best effort; a failure is retried on the next write.
    private func excludeFromBackup() {
        guard !excludedFromBackup else { return }
        var directory = self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        excludedFromBackup = (try? directory.setResourceValues(values)) != nil
    }

    /// Writes `data` to `url` and flushes it to disk before returning, so the
    /// rename that follows cannot expose a file whose contents a power loss
    /// would lose (and the next load would then quarantine).
    private func writeSynchronized(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    func quarantine(_ completion: @escaping (Result<Void, Error>) -> Void) {
        ioQueue.async {
            let fileManager = FileManager.default
            do {
                if fileManager.fileExists(atPath: self.fileURL.path) {
                    if fileManager.fileExists(atPath: self.corruptURL.path) {
                        try fileManager.removeItem(at: self.corruptURL)
                    }
                    try fileManager.moveItem(at: self.fileURL, to: self.corruptURL)
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
