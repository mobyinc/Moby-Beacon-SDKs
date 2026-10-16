import Foundation

/// A validated copy of a `MobyBeaconConfig`, taken when the SDK starts.
struct Settings {
    let endpoint: String
    let apiKey: String
    let userId: String
    let flushInterval: TimeInterval
    let batchSize: Int
    let maxQueueSize: Int
    let onError: ((MobyBeaconError) -> Void)?
}

@objc(MobyBeaconConfig)
public final class MobyBeaconConfig: NSObject {
    /// API base URL, without a trailing slash. Events are sent to
    /// `{endpoint}/events`.
    @objc public let endpoint: String
    /// Ingest API key, sent as the `X-API-Key` header.
    @objc public let apiKey: String
    /// Default user ID attached to every event.
    @objc public let userId: String
    /// Seconds between automatic flushes when sends are succeeding.
    @objc public var flushInterval: TimeInterval = 5
    /// Flush as soon as this many events are queued.
    @objc public var batchSize: Int = 10
    /// Maximum number of events held on disk. New events are rejected when full.
    @objc public var maxQueueSize: Int = 10_000
    /// Called when events are rejected, dropped, or queued for retry (see
    /// `MobyBeaconError.willRetry`). Without it, failures are silent.
    @objc public var onError: ((MobyBeaconError) -> Void)?

    @objc(initWithEndpoint:apiKey:userId:error:)
    public init(endpoint: String, apiKey: String, userId: String) throws {
        var stripped = Substring(endpoint)
        while stripped.last == "/" { stripped.removeLast() }

        guard let components = URLComponents(string: String(stripped)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw MobyBeaconSetupError.invalidEndpoint(endpoint)
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MobyBeaconSetupError.emptyAPIKey
        }
        if userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MobyBeaconSetupError.emptyUserId
        }
        if userId.utf16.count > maxFieldLength {
            throw MobyBeaconSetupError.userIdTooLong
        }
        if userId.utf16.contains(0) {
            throw MobyBeaconSetupError.userIdContainsNUL
        }

        self.endpoint = String(stripped)
        self.apiKey = apiKey
        self.userId = userId
        super.init()
    }

    /// Re-checks the options that can be changed after creation and returns
    /// a snapshot of the configuration.
    func validatedSettings() throws -> Settings {
        guard flushInterval > 0 else { throw MobyBeaconSetupError.nonPositiveFlushInterval }
        guard batchSize >= 1 else { throw MobyBeaconSetupError.batchSizeBelowOne }
        guard maxQueueSize >= 1 else { throw MobyBeaconSetupError.maxQueueSizeBelowOne }
        return Settings(
            endpoint: endpoint,
            apiKey: apiKey,
            userId: userId,
            flushInterval: flushInterval,
            batchSize: batchSize,
            maxQueueSize: maxQueueSize,
            onError: onError)
    }
}
