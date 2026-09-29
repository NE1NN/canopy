import Foundation

/// An HTTP reply, whatever its status.
public struct HTTPReply: Sendable, Equatable {
    public var status: Int
    /// Keys lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// How the plugin reaches ticket-manager. Tests put ticket-manager in memory behind it.
public protocol TicketTransport: Sendable {
    /// GETs `url` with `Authorization: Bearer <token>`. Throws `URLError` when no reply comes. A redirect comes back as
    /// the 3xx reply itself.
    func get(_ url: URL, token: String) async throws -> HTTPReply
}

/// URLSession with nothing kept between requests: no cookies, no cache, and no stored credentials. Requests give up
/// after 15 seconds, and redirects are refused, so the token never follows one somewhere else.
public final class URLSessionTicketTransport: TicketTransport {
    public static let timeout: TimeInterval = 15
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: RefusingRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func get(_ url: URL, token: String) async throws -> HTTPReply {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return HTTPReply(status: response.statusCode, headers: headers, body: data)
    }
}

private final class RefusingRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
