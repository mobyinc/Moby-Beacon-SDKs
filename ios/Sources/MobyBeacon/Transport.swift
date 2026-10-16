import Foundation

struct EventBatchResponse: Equatable {
    let accepted: Int
    let errors: [EventBatchError]

    /// Returns nil unless `jsonObject` is the response object. A missing
    /// `accepted` counts as 0 and a missing `errors` as none.
    init?(jsonObject: Any) {
        guard let json = jsonObject as? [String: Any] else { return nil }
        let errors: [EventBatchError]
        switch json["errors"] {
        case nil, is NSNull:
            errors = []
        case let list as [Any]:
            let parsed = list.compactMap { ($0 as? [String: Any]).flatMap(EventBatchError.init(jsonObject:)) }
            guard parsed.count == list.count else { return nil }
            errors = parsed
        default:
            return nil
        }
        self.accepted = (json["accepted"] as? NSNumber)?.intValue ?? 0
        self.errors = errors
    }

    init(accepted: Int, errors: [EventBatchError]) {
        self.accepted = accepted
        self.errors = errors
    }
}

struct TransportError: Error, Equatable {
    let message: String
    /// HTTP status, or nil when the request never got a response.
    let statusCode: Int?
    /// Seconds from the `Retry-After` header on a 429.
    let retryAfter: Int?

    init(_ message: String, statusCode: Int? = nil, retryAfter: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
        self.retryAfter = retryAfter
    }

    init(message: String, statusCode: Int?, retryAfter: Int?) {
        self.init(message, statusCode: statusCode, retryAfter: retryAfter)
    }
}

/// Sends event batches to `POST {endpoint}/events`.
class Transport {
    private let url: URL
    private let apiKey: String
    private let client: HTTPClient
    private let ownsClient: Bool

    init(endpoint: String, apiKey: String, client: HTTPClient? = nil, timeout: TimeInterval = 30) {
        self.url = URL(string: "\(endpoint)/events")!
        self.apiKey = apiKey
        self.client = client ?? URLSessionHTTPClient(timeout: timeout)
        self.ownsClient = client == nil
    }

    /// Completes with the API response for 201, 207 and 422, and with a
    /// `TransportError` for everything else.
    func send(_ events: [MobyBeaconEvent], completion: @escaping (Result<EventBatchResponse, Error>) -> Void) {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: ["events": events.map { $0.toJSONObject() }])
        } catch {
            completion(.failure(TransportError("Network error: \(error.localizedDescription)")))
            return
        }
        let request = HTTPRequest(
            url: url,
            headers: ["Content-Type": "application/json", "X-API-Key": apiKey],
            body: body)
        client.post(request) { result in
            switch result {
            case .success(let response):
                completion(Transport.interpret(response))
            case .failure(let error):
                if (error as? URLError)?.code == .timedOut {
                    completion(.failure(TransportError("Request timed out")))
                } else {
                    completion(.failure(TransportError("Network error: \(error.localizedDescription)")))
                }
            }
        }
    }

    func close() {
        if ownsClient { client.invalidate() }
    }

    private static func interpret(_ response: HTTPResponse) -> Result<EventBatchResponse, Error> {
        let status = response.statusCode
        if status == 429 {
            return .failure(TransportError(
                "Rate limited", statusCode: 429, retryAfter: retryAfterSeconds(from: response.headers)))
        }
        if status >= 500 {
            return .failure(TransportError("Server error: \(status)", statusCode: status))
        }
        if status >= 300 && status < 400 {
            return .failure(TransportError(
                "Unexpected redirect (\(status)); check the endpoint URL", statusCode: status))
        }
        if status == 201 || status == 207 || status == 422 {
            // The server took the batch; an unreadable body carries no
            // per-event errors to report.
            let parsed = (try? JSONSerialization.jsonObject(with: response.body)).flatMap(EventBatchResponse.init(jsonObject:))
            return .success(parsed ?? EventBatchResponse(accepted: 0, errors: []))
        }
        return .failure(TransportError("Client error: \(status)", statusCode: status))
    }
}

/// Seconds to wait from `Retry-After`, or from the longest of the
/// `Retry-After-<name>` headers that NestJS named throttlers send instead.
/// Header names arrive lowercased; HTTP-date values are not integers and so
/// are ignored.
func retryAfterSeconds(from headers: [String: String]) -> Int? {
    if let plain = headers["retry-after"].flatMap({ Int($0) }) { return plain }
    var longest: Int?
    for (name, value) in headers where name.hasPrefix("retry-after-") {
        if let seconds = Int(value), longest == nil || seconds > longest! {
            longest = seconds
        }
    }
    return longest
}
