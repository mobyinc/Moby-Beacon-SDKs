import Foundation

/// UTC ISO 8601 timestamps in the wire format `2026-10-07T12:00:00.000Z`.
enum ISO8601 {
    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    // ISO8601DateFormatter is thread-safe, so shared instances are fine.
    private static let withFraction = makeFormatter(fractionalSeconds: true)
    private static let withoutFraction = makeFormatter(fractionalSeconds: false)

    static func string(from date: Date) -> String {
        withFraction.string(from: date)
    }

    /// Accepts timestamps with or without fractional seconds.
    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }
}
