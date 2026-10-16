import Foundation

struct HTTPRequest {
    let url: URL
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    let statusCode: Int
    /// Header names, lowercased.
    let headers: [String: String]
    let body: Data
}

/// The seam between `Transport` and the network, so tests can answer requests
/// without one.
protocol HTTPClient: AnyObject {
    /// Posts `request` and completes once, on any thread, with the response or
    /// the client-level failure.
    func post(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, Error>) -> Void)

    /// Releases the client's resources. Requests already in flight finish.
    func invalidate()
}

/// An `HTTPClient` over an ephemeral `URLSession` that never follows
/// redirects, so a misconfigured endpoint is reported instead of replayed.
final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate {
    private var session: URLSession!

    init(timeout: TimeInterval) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func post(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        session.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                completion(.failure(error))
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    if let name = name as? String, let value = value as? String {
                        headers[name.lowercased()] = value
                    }
                }
                completion(.success(HTTPResponse(statusCode: http.statusCode, headers: headers, body: data ?? Data())))
            } else {
                completion(.failure(URLError(.badServerResponse)))
            }
        }.resume()
    }

    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
