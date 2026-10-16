import Foundation

/// Longest `userId`, `category`, `action` or details key the API accepts.
let maxFieldLength = 255
private let maxDetailKeys = 50
private let maxDetailStringLength = 1000

/// A violation of the API's ingest rules.
struct ValidationError: Error, Equatable {
    let message: String
}

/// Checks `event` against the API's ingest rules. Throws a `ValidationError`
/// with a descriptive message on the first violation.
func validateEvent(_ event: MobyBeaconEvent) throws {
    try validateRequiredString(event.userId, field: "userId")
    try validateRequiredString(event.category, field: "category")
    try validateRequiredString(event.action, field: "action")

    guard let details = event.details else { return }

    if details.count > maxDetailKeys {
        throw ValidationError(message: "details must have at most \(maxDetailKeys) keys")
    }
    for (key, value) in details {
        if key.utf16.count > maxFieldLength {
            throw ValidationError(message: "details key must be at most \(maxFieldLength) characters")
        }
        if containsNUL(key) {
            throw ValidationError(message: "details keys must not contain NUL characters")
        }
        if let string = value as? String {
            if string.utf16.count > maxDetailStringLength {
                throw ValidationError(message: "details string values must be at most \(maxDetailStringLength) characters")
            }
            if containsNUL(string) {
                throw ValidationError(message: "details.\(key) must not contain NUL characters")
            }
        } else if let number = value as? NSNumber {
            if !isBoolean(number) && !number.doubleValue.isFinite {
                throw ValidationError(message: "details.\(key) must be a finite number")
            }
        } else if !(value is NSNull) {
            throw ValidationError(
                message: "details.\(key) must be a string, number, boolean, or null — not a nested object or array")
        }
    }
}

/// Whether `value` is something the API accepts as a details value: null, a
/// string, a boolean or a finite number.
func isValidDetailValue(_ value: Any?) -> Bool {
    guard let value = value else { return true }
    if value is NSNull || value is String { return true }
    if let number = value as? NSNumber {
        return isBoolean(number) || number.doubleValue.isFinite
    }
    return false
}

private func validateRequiredString(_ value: String, field: String) throws {
    if value.isEmpty {
        throw ValidationError(message: "\(field) is required and must be a non-empty string")
    }
    if field == "userId" && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ValidationError(message: "userId must not be blank")
    }
    if value.utf16.count > maxFieldLength {
        throw ValidationError(message: "\(field) must be at most \(maxFieldLength) characters")
    }
    if containsNUL(value) {
        throw ValidationError(message: "\(field) must not contain NUL characters")
    }
}

private func containsNUL(_ value: String) -> Bool {
    value.utf16.contains(0)
}

private func isBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

/// Returns `event` with every unpaired UTF-16 surrogate in its strings
/// (`userId`, `category`, `action`, details keys and string values) replaced
/// by U+FFFD, and its details copied one level deep.
///
/// Truncating text in the middle of an emoji leaves a lone surrogate. Encoded
/// as JSON it becomes an escape that PostgreSQL rejects, which would fail the
/// whole batch on every retry.
///
/// The copy makes the event independent of the caller: `NSMutableString`
/// values become native strings, and arrays and dictionaries in details
/// (which validation rejects) are snapshotted one level deep, so later
/// changes by the caller can neither alter the queued event nor race with
/// encoding it.
func sanitizeEvent(_ event: MobyBeaconEvent) -> MobyBeaconEvent {
    MobyBeaconEvent(
        userId: sanitizeString(event.userId),
        category: sanitizeString(event.category),
        action: sanitizeString(event.action),
        timestamp: event.timestamp,
        details: event.details.map { sanitizeDictionary($0) })
}

private func sanitizeDictionary(_ dictionary: [String: Any], copyingContainers: Bool = true) -> [String: Any] {
    var cleaned: [String: Any] = [:]
    for (key, value) in dictionary {
        cleaned[sanitizeString(key)] = sanitizeValue(value, copyingContainers: copyingContainers)
    }
    return cleaned
}

/// Bridging an `NSArray` or `NSDictionary` to a Swift collection copies it,
/// so a container is snapshotted before its elements are read. Only details
/// values are copied this way; containers inside them are kept as they are.
/// Validation rejects the outer container anyway, and copying stops there so
/// a self-containing array cannot recurse forever.
///
/// A Swift optional that is `nil` (e.g. `["note": note]` with `note: String?`)
/// becomes `NSNull`, so it is sent as JSON `null` rather than rejected.
private func sanitizeValue(_ value: Any, copyingContainers: Bool) -> Any {
    if case Optional<Any>.none = value { return NSNull() }
    if let string = value as? String { return sanitizeString(string) }
    if value is NSNumber || value is NSNull { return value }
    guard copyingContainers else { return value }
    if let array = value as? [Any] { return array.map { sanitizeValue($0, copyingContainers: false) } }
    if let dictionary = value as? [String: Any] { return sanitizeDictionary(dictionary, copyingContainers: false) }
    return value
}

/// Replaces unpaired UTF-16 surrogates in `value` with U+FFFD.
///
/// The UTF-8 view of a bridged string already repairs lone surrogates;
/// re-materialising it gives a native string that `JSONSerialization` accepts.
func sanitizeString(_ value: String) -> String {
    String(decoding: Array(value.utf8), as: UTF8.self)
}
