import Foundation

/// Thrown when a `MobyBeaconConfig` cannot be created or `MobyBeacon` cannot
/// be started. Into Objective-C it arrives as an `NSError` in the
/// `MobyBeaconSetupErrorInfo.domain` domain, with a `MobyBeaconSetupErrorCode`
/// as its code.
public enum MobyBeaconSetupError: Error, LocalizedError, Equatable {
    case invalidEndpoint(String)
    case emptyAPIKey
    case emptyUserId
    case userIdTooLong
    case userIdContainsNUL
    case nonPositiveFlushInterval
    case batchSizeBelowOne
    case maxQueueSizeBelowOne
    case alreadyRunning
    case storageUnavailable(String)
    case apiKeyContainsControlCharacters

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "endpoint must be an absolute http(s) URL: \(endpoint)"
        case .emptyAPIKey:
            return "apiKey must not be empty"
        case .emptyUserId:
            return "userId must not be empty"
        case .userIdTooLong:
            return "userId must be at most \(maxFieldLength) characters"
        case .userIdContainsNUL:
            return "userId must not contain NUL characters"
        case .nonPositiveFlushInterval:
            return "flushInterval must be positive"
        case .batchSizeBelowOne:
            return "batchSize must be at least 1"
        case .maxQueueSizeBelowOne:
            return "maxQueueSize must be at least 1"
        case .alreadyRunning:
            return "MobyBeacon is already running"
        case .storageUnavailable(let reason):
            return "the event queue could not be opened: \(reason)"
        case .apiKeyContainsControlCharacters:
            return "apiKey must not contain control characters"
        }
    }

    /// The stable code this error carries as an `NSError`.
    public var code: MobyBeaconSetupErrorCode {
        switch self {
        case .invalidEndpoint: return .invalidEndpoint
        case .emptyAPIKey: return .emptyAPIKey
        case .emptyUserId: return .emptyUserId
        case .userIdTooLong: return .userIdTooLong
        case .userIdContainsNUL: return .userIdContainsNUL
        case .nonPositiveFlushInterval: return .nonPositiveFlushInterval
        case .batchSizeBelowOne: return .batchSizeBelowOne
        case .maxQueueSizeBelowOne: return .maxQueueSizeBelowOne
        case .alreadyRunning: return .alreadyRunning
        case .storageUnavailable: return .storageUnavailable
        case .apiKeyContainsControlCharacters: return .apiKeyContainsControlCharacters
        }
    }
}

/// The `NSError` code of each `MobyBeaconSetupError` case. The raw values
/// are part of the Objective-C API and never change; 0 is unused.
@objc public enum MobyBeaconSetupErrorCode: Int {
    case invalidEndpoint = 1
    case emptyAPIKey = 2
    case emptyUserId = 3
    case userIdTooLong = 4
    case userIdContainsNUL = 5
    case nonPositiveFlushInterval = 6
    case batchSizeBelowOne = 7
    case maxQueueSizeBelowOne = 8
    case alreadyRunning = 9
    case storageUnavailable = 10
    case apiKeyContainsControlCharacters = 11
}

/// Exposes the `NSError` domain of `MobyBeaconSetupError` to Objective-C.
@objc public final class MobyBeaconSetupErrorInfo: NSObject {
    /// The domain of every `MobyBeaconSetupError` bridged to `NSError`.
    @objc public static let domain = "MobyBeacon.SetupError"
}

extension MobyBeaconSetupError: CustomNSError {
    public static var errorDomain: String { MobyBeaconSetupErrorInfo.domain }

    public var errorCode: Int { code.rawValue }

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? ""]
    }
}
