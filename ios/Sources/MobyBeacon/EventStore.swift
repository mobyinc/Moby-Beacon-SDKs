import Foundation

/// Why `EventStore.add` rejected an event.
enum StoreError: Error, Equatable {
    /// The queue already holds `maxSize` events.
    case atCapacity
    /// The event cannot be encoded as JSON.
    case notEncodable
}

/// `EventStore.load` called out of order: a programming error.
enum StoreMisuse: Error {
    case loadCalledTwice
    case loadAfterMutation
}

/// FIFO queue of events, mirrored to `QueueStorage` so it survives restarts.
///
/// Mutations apply to memory immediately and schedule a write. At most one
/// write runs at a time; changes made during a write are picked up by a
/// single follow-up write.
///
/// The stored file is `{"v":1,"events":[...]}`.
///
/// Every method must be called on `scheduler`'s serial context; storage
/// completions are re-dispatched onto it before touching any state.
final class EventStore {
    /// An event together with its JSON, encoded once so writes never re-encode
    /// the whole queue, and that JSON's UTF-8 size for byte-bounded batches.
    private struct Entry {
        let event: MobyBeaconEvent
        let json: String
        let bytes: Int
    }

    private static let version = 1

    private let storage: QueueStorage
    private let scheduler: Scheduler
    let maxSize: Int

    /// Called with a human-readable message when stored events could not be
    /// read and were dropped. Settable so the owner can wire it after creation.
    var onDiscarded: ((String) -> Void)?

    private var entries: [Entry] = []

    /// A write drain is running; `writeWaiters` run when it finishes.
    private var writing = false
    private var writeWaiters: [() -> Void] = []

    /// A read of storage is in flight; `readWaiters` run when it settles.
    private var reading = false
    private var readWaiters: [() -> Void] = []

    /// A mutation has not been written yet.
    private var dirty = false

    /// The last write failed, so disk may not match memory.
    private var stale = false

    /// The stored queue has not been read yet. Writing now would overwrite a
    /// backlog we have not seen, so writes wait until a read succeeds.
    private var unread = false

    private var loadCalled = false
    private var mutated = false

    init(storage: QueueStorage, maxSize: Int, scheduler: Scheduler) {
        self.storage = storage
        self.maxSize = maxSize
        self.scheduler = scheduler
    }

    var count: Int {
        entries.count
    }

    /// Loads persisted events. Call once, before any mutation; throws
    /// `StoreMisuse` otherwise.
    ///
    /// Never fails for storage or content problems: unparseable content is
    /// quarantined and reported via `onDiscarded`; unavailable storage is
    /// retried before each later write. `completion` runs on the scheduler
    /// once the read attempt has settled.
    func load(_ completion: @escaping () -> Void) throws {
        if loadCalled { throw StoreMisuse.loadCalledTwice }
        if mutated { throw StoreMisuse.loadAfterMutation }
        loadCalled = true
        unread = true
        ensureRead(completion)
    }

    /// Appends `event`. Throws `StoreError.atCapacity` when the queue holds
    /// `maxSize` events, or `StoreError.notEncodable` if the event cannot be
    /// encoded as JSON.
    func add(_ event: MobyBeaconEvent) throws {
        if entries.count >= maxSize { throw StoreError.atCapacity }
        guard let entry = Self.entry(for: event) else { throw StoreError.notEncodable }
        mutated = true
        entries.append(entry)
        scheduleWrite()
    }

    /// Returns up to `count` events from the front without removing them.
    ///
    /// With `maxBytes`, returns the longest such prefix whose UTF-8 encoded
    /// events, plus one comma between each, fit in `maxBytes`. At least one
    /// event is returned whenever the queue is non-empty, even if it alone is
    /// larger, so the caller can still send (or drop) it.
    func peek(_ count: Int, maxBytes: Int? = nil) -> [MobyBeaconEvent] {
        var n = max(0, min(count, entries.count))
        if let maxBytes, n > 1 {
            var total = entries[0].bytes
            var fits = 1
            while fits < n {
                total += 1 + entries[fits].bytes
                if total > maxBytes { break }
                fits += 1
            }
            n = fits
        }
        return entries.prefix(n).map(\.event)
    }

    /// Removes up to `count` events from the front.
    func removeFirst(_ count: Int) {
        mutated = true
        let n = min(count, entries.count)
        guard n > 0 else { return }
        entries.removeFirst(n)
        scheduleWrite()
    }

    /// Waits for any in-flight write, then makes one more attempt if disk may
    /// still differ from memory. Never fails; `completion` runs on the
    /// scheduler once that has settled.
    func persist(_ completion: @escaping () -> Void) {
        if writing {
            writeWaiters.append { [self] in persistAfterInFlightWrite(completion) }
        } else {
            persistAfterInFlightWrite(completion)
        }
    }

    private func persistAfterInFlightWrite(_ completion: @escaping () -> Void) {
        guard dirty || stale || unread else {
            scheduler.async(completion)
            return
        }
        dirty = true
        writeWaiters.append(completion)
        startDrainIfIdle()
    }

    // MARK: Writing

    private func scheduleWrite() {
        dirty = true
        startDrainIfIdle()
    }

    private func startDrainIfIdle() {
        guard !writing else { return }
        writing = true
        // Start on a later turn so every mutation made in this one is
        // coalesced into the first write.
        scheduler.async { [self] in drainWrites() }
    }

    /// One pass of the drain loop: writes while `dirty`, reading first while
    /// `unread`, then finishes.
    private func drainWrites() {
        guard dirty else { return finishDrain() }
        guard !unread else {
            ensureRead { [self] in
                // Still unavailable: leave `dirty` set so a later attempt retries.
                if unread { return finishDrain() }
                writeOnce()
            }
            return
        }
        writeOnce()
    }

    private func writeOnce() {
        dirty = false
        storage.write(encode()) { [self] result in
            scheduler.async { [self] in
                switch result {
                case .success:
                    stale = false
                case .failure:
                    // Keep working from memory; persist() or the next mutation retries.
                    stale = true
                }
                drainWrites()
            }
        }
    }

    private func finishDrain() {
        writing = false
        let waiters = writeWaiters
        writeWaiters = []
        waiters.forEach { $0() }
    }

    private func encode() -> String {
        #"{"v":\#(Self.version),"events":["# + entries.map(\.json).joined(separator: ",") + "]}"
    }

    // MARK: Reading

    /// Reads storage unless a read is already in flight, then runs `done`
    /// once that read has settled.
    private func ensureRead(_ done: @escaping () -> Void) {
        readWaiters.append(done)
        guard !reading else { return }
        reading = true
        storage.read { [self] result in
            scheduler.async { [self] in handleRead(result) }
        }
    }

    private func handleRead(_ result: Result<String?, Error>) {
        guard case .success(let contents) = result else {
            // Unavailable (e.g. iOS before first unlock); retry later.
            return finishRead()
        }
        guard let contents else {
            unread = false
            return finishRead()
        }
        guard let (loaded, skipped) = Self.parse(contents) else {
            storage.quarantine { [self] _ in
                // Whether or not quarantine worked, start empty.
                scheduler.async { [self] in
                    unread = false
                    report("Persisted event queue was unreadable and has been discarded")
                    finishRead()
                }
            }
            return
        }
        unread = false
        // Append, never prepend: a flush may have peeked the front of the
        // queue and will remove exactly that many events when it finishes.
        entries.append(contentsOf: loaded)
        if skipped > 0 {
            report("\(skipped) persisted event(s) were unreadable and have been discarded")
            scheduleWrite() // Drop the bad entries from disk.
        }
        finishRead()
    }

    private func finishRead() {
        reading = false
        let waiters = readWaiters
        readWaiters = []
        waiters.forEach { $0() }
    }

    private func report(_ message: String) {
        onDiscarded?(message)
    }

    // MARK: Encoding

    /// Encodes `event` once, or returns nil if it cannot be encoded as JSON.
    private static func entry(for event: MobyBeaconEvent) -> Entry? {
        let object = event.toJSONObject()
        // Checked first: JSONSerialization raises an uncatchable exception
        // for values such as Date or NaN.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return Entry(event: event, json: String(decoding: data, as: UTF8.self), bytes: data.count)
    }

    /// Returns the stored entries and how many were skipped, or nil if the
    /// content as a whole is unreadable.
    private static func parse(_ contents: String) -> (entries: [Entry], skipped: Int)? {
        guard let decoded = try? JSONSerialization.jsonObject(with: repairingLoneSurrogateEscapes(contents)),
              let file = decoded as? [String: Any],
              let version = file["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(Self.version),
              let stored = file["events"] as? [Any]
        else { return nil }

        var entries: [Entry] = []
        var skipped = 0
        for json in stored {
            guard let object = json as? [String: Any],
                  let parsed = MobyBeaconEvent(jsonObject: object)
            else {
                skipped += 1
                continue
            }
            let event = sanitizeEvent(parsed)
            guard (try? validateEvent(event)) != nil, let entry = entry(for: event) else {
                skipped += 1
                continue
            }
            entries.append(entry)
        }
        return (entries, skipped)
    }

    /// Returns `contents` as UTF-8 with every `\uXXXX` escape of an unpaired
    /// UTF-16 surrogate replaced by `�`.
    ///
    /// JSONSerialization rejects the whole document for one such escape, which
    /// would discard the queue; Dart's decoder accepts it and `sanitizeEvent`
    /// repairs the string. Escapes and their hex digits are ASCII, which never
    /// occurs inside a multi-byte UTF-8 sequence, so scanning bytes is safe.
    private static func repairingLoneSurrogateEscapes(_ contents: String) -> Data {
        let bytes = Array(contents.utf8)
        guard bytes.contains(UInt8(ascii: "\\")) else { return Data(bytes) }

        func codeUnit(at i: Int) -> UInt16? {
            guard i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u"),
                  let value = UInt16(String(decoding: bytes[(i + 2)..<(i + 6)], as: UTF8.self), radix: 16)
            else { return nil }
            return value
        }

        let replacement = Array(#"�"#.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard let unit = codeUnit(at: i), (0xD800...0xDFFF).contains(unit) else {
                // Any other escape, including `\\`, is copied as a pair so its
                // second character is never mistaken for the start of one.
                out.append(contentsOf: bytes[i...(i + 1)])
                i += 2
                continue
            }
            if unit <= 0xDBFF, let low = codeUnit(at: i + 6), (0xDC00...0xDFFF).contains(low) {
                out.append(contentsOf: bytes[i..<(i + 12)])
                i += 12
            } else {
                out.append(contentsOf: replacement)
                i += 6
            }
        }
        return Data(out)
    }
}
