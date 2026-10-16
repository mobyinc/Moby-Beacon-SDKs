import Foundation

/// A single study event, in the shape sent to `POST /events`.
@objc(MobyBeaconEvent)
public final class MobyBeaconEvent: NSObject {
    @objc public let userId: String
    @objc public let category: String
    @objc public let action: String
    @objc public let timestamp: Date
    @objc public let details: [String: Any]?

    @objc public init(userId: String, category: String, action: String, timestamp: Date, details: [String: Any]?) {
        self.userId = userId
        self.category = category
        self.action = action
        self.timestamp = timestamp
        self.details = details
        super.init()
    }

    func toJSONObject() -> [String: Any] {
        var json: [String: Any] = [
            "userId": userId,
            "category": category,
            "action": action,
            "timestamp": ISO8601.string(from: timestamp),
        ]
        if let details = details {
            json["details"] = details
        }
        return json
    }

    /// Returns nil when a required key is missing or not a string, when the
    /// timestamp cannot be parsed, or when `details` is neither absent, null
    /// nor an object.
    convenience init?(jsonObject: [String: Any]) {
        guard let userId = jsonObject["userId"] as? String,
              let category = jsonObject["category"] as? String,
              let action = jsonObject["action"] as? String,
              let timestampString = jsonObject["timestamp"] as? String,
              let timestamp = ISO8601.date(from: timestampString)
        else { return nil }

        let details: [String: Any]?
        switch jsonObject["details"] {
        case nil, is NSNull:
            details = nil
        case let value as [String: Any]:
            details = value
        default:
            return nil
        }
        self.init(userId: userId, category: category, action: action, timestamp: timestamp, details: details)
    }
}

/// A per-event rejection returned by the API in a 207 or 422 response.
@objc(MobyBeaconEventBatchError)
public final class EventBatchError: NSObject {
    /// Position of the rejected event in the sent batch.
    @objc public let index: Int
    @objc public let message: String

    @objc public init(index: Int, message: String) {
        self.index = index
        self.message = message
        super.init()
    }

    convenience init?(jsonObject: [String: Any]) {
        guard let index = (jsonObject["index"] as? NSNumber)?.intValue,
              let message = jsonObject["message"] as? String
        else { return nil }
        self.init(index: index, message: message)
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? EventBatchError else { return false }
        return index == other.index && message == other.message
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(index)
        hasher.combine(message)
        return hasher.finalize()
    }
}
