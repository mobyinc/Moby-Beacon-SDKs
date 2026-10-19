import Foundation

@objc public enum MobyBeaconErrorType: Int {
    case network, server, auth, validation

    var name: String {
        switch self {
        case .network: return "network"
        case .server: return "server"
        case .auth: return "auth"
        case .validation: return "validation"
        }
    }
}

extension MobyBeaconErrorType: CustomStringConvertible {
    /// The lowercase case name, e.g. `network`.
    public var description: String { name }
}

/// Reported through `MobyBeaconConfig.onError`.
@objc(MobyBeaconError)
public final class MobyBeaconError: NSObject {
    @objc public let type: MobyBeaconErrorType
    @objc public let message: String
    /// The events affected. For server validation errors this is the full
    /// sent batch, so `errors` indexes line up with it.
    @objc public let events: [MobyBeaconEvent]
    /// Per-event errors from a 207/422 response.
    @objc public let errors: [EventBatchError]?
    /// True when `events` are still queued and will be retried.
    @objc public let willRetry: Bool

    @objc public init(
        type: MobyBeaconErrorType,
        message: String,
        events: [MobyBeaconEvent],
        errors: [EventBatchError]?,
        willRetry: Bool
    ) {
        self.type = type
        self.message = message
        self.events = events
        self.errors = errors
        self.willRetry = willRetry
        super.init()
    }

    public override var description: String {
        "MobyBeaconError(\(type.name)): \(message)"
    }
}
