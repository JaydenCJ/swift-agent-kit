import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal HTTP request description.
public struct HTTPRequest: Sendable {
    /// The request URL.
    public var url: URL
    /// The HTTP method (default `POST`).
    public var method: String
    /// HTTP header fields.
    public var headers: [String: String]
    /// The request body, if any.
    public var body: Data?

    /// Creates a request description.
    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

/// A minimal HTTP response.
public struct HTTPResponse: Sendable {
    /// The HTTP status code.
    public var statusCode: Int
    /// Response header fields.
    public var headers: [String: String]
    /// The full response body.
    public var body: Data

    /// Creates a response description.
    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Abstraction over the HTTP layer, so providers can be unit tested without
/// a network and apps can inject custom stacks (retries, logging, pinning).
public protocol HTTPTransport: Sendable {
    /// Performs a buffered request/response exchange.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse

    /// Performs a request and returns the response body as a byte stream.
    ///
    /// Non-2xx responses surface as ``AgentKitError/httpError(statusCode:message:)``
    /// thrown from the stream.
    func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error>
}

/// `URLSession`-backed transport. Works on Apple platforms and Linux
/// (via FoundationNetworking).
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let session: URLSession

    /// Creates a transport with its own `URLSession`.
    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        self.session = URLSession(configuration: configuration)
    }

    private func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = makeURLRequest(request)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    continuation.resume(throwing: AgentKitError.transport("\(error)"))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: AgentKitError.transport("Non-HTTP response"))
                    return
                }
                var headers: [String: String] = [:]
                for (name, value) in http.allHeaderFields {
                    if let name = name as? String, let value = value as? String {
                        headers[name] = value
                    }
                }
                continuation.resume(returning: HTTPResponse(
                    statusCode: http.statusCode,
                    headers: headers,
                    body: data ?? Data()
                ))
            }
            task.resume()
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        let urlRequest = makeURLRequest(request)
        let delegate = StreamingDelegate()
        let streamSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return AsyncThrowingStream { continuation in
            delegate.continuation = continuation
            let task = streamSession.dataTask(with: urlRequest)
            continuation.onTermination = { _ in
                task.cancel()
                streamSession.finishTasksAndInvalidate()
            }
            task.resume()
        }
    }
}

/// Feeds URLSession delegate callbacks into an `AsyncThrowingStream`.
/// URLSession serializes delegate callbacks, so unsynchronized access to the
/// stored properties is safe.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var statusCode: Int = 0
    private var errorBody = Data()

    private var isSuccess: Bool { (200..<300).contains(statusCode) }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if isSuccess {
            continuation?.yield(data)
        } else {
            errorBody.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.finish(throwing: AgentKitError.transport("\(error)"))
        } else if !isSuccess {
            continuation?.finish(throwing: AgentKitError.httpError(
                statusCode: statusCode,
                message: String(data: errorBody, encoding: .utf8)
            ))
        } else {
            continuation?.finish()
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}
