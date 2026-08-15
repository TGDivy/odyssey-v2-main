import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OdysseyDomain

public struct URLSessionSyncTransportConfiguration: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let userAgent: String
    public let allowsInsecureTransportForTesting: Bool

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30,
        maximumRequestBytes: Int = 8 * 1_024 * 1_024,
        maximumResponseBytes: Int = 16 * 1_024 * 1_024,
        userAgent: String = "Odyssey/0",
        allowsInsecureTransportForTesting: Bool = false
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.userAgent = userAgent
        self.allowsInsecureTransportForTesting = allowsInsecureTransportForTesting
    }
}

public enum SyncTransportError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case network(code: Int)
    case nonHTTPResponse
    case redirected(expectedOrigin: String, actualOrigin: String)
    case responseTooLarge(maximumBytes: Int)
    case api(statusCode: Int, error: APIErrorBody)
    case invalidResponse(statusCode: Int, correlationID: String?)
}

extension SyncTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .invalidRequest(message):
            message
        case let .network(code):
            "The sync request failed at the network layer (URL error \(code))."
        case .nonHTTPResponse:
            "The sync endpoint returned a non-HTTP response."
        case let .redirected(expectedOrigin, actualOrigin):
            "The sync endpoint redirected from \(expectedOrigin) to \(actualOrigin)."
        case let .responseTooLarge(maximumBytes):
            "The sync response exceeded the \(maximumBytes)-byte safety limit."
        case let .api(statusCode, error):
            "The sync API returned HTTP \(statusCode): \(error.code)."
        case let .invalidResponse(statusCode, correlationID):
            if let correlationID {
                "The sync API returned an invalid HTTP \(statusCode) response (correlation \(correlationID))."
            } else {
                "The sync API returned an invalid HTTP \(statusCode) response."
            }
        }
    }
}

public actor URLSessionSyncTransport: SyncTransport {
    private let configuration: URLSessionSyncTransportConfiguration
    private let tokenProvider: any BearerTokenProvider
    private let loader: any SyncHTTPDataLoading
    private let retainedSession: URLSession?
    private let retainedDelegate: RedirectRejectingURLSessionDelegate?

    public init(
        configuration: URLSessionSyncTransportConfiguration,
        tokenProvider: any BearerTokenProvider
    ) throws {
        try Self.validate(configuration)
        let delegate = RedirectRejectingURLSessionDelegate()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpMaximumConnectionsPerHost = 4
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        loader = URLSessionHTTPDataLoader(session: session)
        retainedSession = session
        retainedDelegate = delegate
    }

    init(
        configuration: URLSessionSyncTransportConfiguration,
        tokenProvider: any BearerTokenProvider,
        loader: any SyncHTTPDataLoading
    ) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.loader = loader
        retainedSession = nil
        retainedDelegate = nil
    }

    public func push(
        _ request: SyncPushRequest,
        batchIdempotencyKey: String
    ) async throws -> SyncPushResponse {
        guard Self.isValidHeaderValue(batchIdempotencyKey),
              (1 ... 500).contains(batchIdempotencyKey.count)
        else {
            throw SyncTransportError.invalidRequest(
                "Batch idempotency keys must contain 1 through 500 header-safe characters."
            )
        }
        return try await send(
            method: "POST",
            path: ["v1", "sync", "push"],
            body: request,
            additionalHeaders: ["Idempotency-Key": batchIdempotencyKey]
        )
    }

    public func pull(
        after cursor: SyncCursor,
        limit: Int,
        deviceID: UUIDv7
    ) async throws -> SyncPullResponse {
        guard (1 ... 500).contains(limit) else {
            throw SyncTransportError.invalidRequest("Sync pull limits must be between 1 and 500.")
        }
        return try await send(
            method: "GET",
            path: ["v1", "sync", "changes"],
            queryItems: [
                URLQueryItem(name: "cursor", value: cursor.description),
                URLQueryItem(name: "limit", value: String(limit)),
            ],
            additionalHeaders: ["X-Odyssey-Device-ID": deviceID.description]
        )
    }

    public func reportDiagnostics(
        deviceID: UUIDv7,
        diagnostics: SyncDeviceDiagnosticsInput
    ) async throws -> SyncDeviceDiagnostics {
        try await send(
            method: "PUT",
            path: ["v1", "sync", "devices", deviceID.description, "diagnostics"],
            body: diagnostics
        )
    }

    public func diagnostics() async throws -> SyncDiagnosticsResponse {
        try await send(
            method: "GET",
            path: ["v1", "sync", "diagnostics"]
        )
    }

    public func conflicts(
        status: SyncConflictStatusFilter,
        limit: Int
    ) async throws -> SyncConflictListResponse {
        guard (1 ... 200).contains(limit) else {
            throw SyncTransportError.invalidRequest("Conflict limits must be between 1 and 200.")
        }
        return try await send(
            method: "GET",
            path: ["v1", "sync", "conflicts"],
            queryItems: [
                URLQueryItem(name: "status", value: status.rawValue),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
    }

    public func resolveConflict(
        conflictID: UUIDv7,
        request: SyncConflictResolutionRequest
    ) async throws -> SyncConflictResolutionResponse {
        try await send(
            method: "POST",
            path: ["v1", "sync", "conflicts", conflictID.description, "resolve"],
            body: request
        )
    }

    private func send<Response: Decodable>(
        method: String,
        path: [String],
        queryItems: [URLQueryItem] = [],
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        try await send(
            method: method,
            path: path,
            queryItems: queryItems,
            encodedBody: nil,
            additionalHeaders: additionalHeaders
        )
    }

    private func send<Body: Encodable, Response: Decodable>(
        method: String,
        path: [String],
        queryItems: [URLQueryItem] = [],
        body: Body,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        let encodedBody = try SyncJSONCoding.makeEncoder().encode(body)
        guard encodedBody.count <= configuration.maximumRequestBytes else {
            throw SyncTransportError.invalidRequest(
                "The encoded sync request exceeds the configured request-size limit."
            )
        }
        return try await send(
            method: method,
            path: path,
            queryItems: queryItems,
            encodedBody: encodedBody,
            additionalHeaders: additionalHeaders
        )
    }

    private func send<Response: Decodable>(
        method: String,
        path: [String],
        queryItems: [URLQueryItem],
        encodedBody: Data?,
        additionalHeaders: [String: String]
    ) async throws -> Response {
        let token = try await tokenProvider.validAccessToken()
        guard Self.isValidHeaderValue(token),
              !token.isEmpty,
              token.utf8.count <= 16 * 1_024
        else {
            throw SyncTransportError.invalidRequest(
                "The bearer-token provider returned an empty or header-unsafe token."
            )
        }
        var request = URLRequest(url: try endpoint(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.httpBody = encodedBody
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Correlation-ID")
        if encodedBody != nil {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in additionalHeaders {
            guard Self.isValidHeaderValue(name), Self.isValidHeaderValue(value) else {
                throw SyncTransportError.invalidRequest("A sync request header is unsafe.")
            }
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch let error as URLError {
            throw SyncTransportError.network(code: error.errorCode)
        } catch let error as SyncTransportError {
            throw error
        } catch {
            throw SyncTransportError.network(code: URLError.unknown.rawValue)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncTransportError.nonHTTPResponse
        }
        try verifyResponseOrigin(httpResponse.url)
        guard data.count <= configuration.maximumResponseBytes else {
            throw SyncTransportError.responseTooLarge(
                maximumBytes: configuration.maximumResponseBytes
            )
        }
        let correlationID = httpResponse.value(forHTTPHeaderField: "X-Correlation-ID")
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let envelope = try? SyncJSONCoding.makeDecoder().decode(
                APIErrorEnvelope.self,
                from: data
            ) {
                throw SyncTransportError.api(
                    statusCode: httpResponse.statusCode,
                    error: envelope.error
                )
            }
            throw SyncTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        guard httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .hasPrefix("application/json") == true
        else {
            throw SyncTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        do {
            return try SyncJSONCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw SyncTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
    }

    private func endpoint(
        path: [String],
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var endpoint = configuration.baseURL
        for component in path {
            endpoint.appendPathComponent(component)
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SyncTransportError.invalidConfiguration("The sync endpoint URL is invalid.")
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw SyncTransportError.invalidRequest("The sync request URL could not be encoded.")
        }
        return url
    }

    private func verifyResponseOrigin(_ responseURL: URL?) throws {
        guard let responseURL else {
            throw SyncTransportError.nonHTTPResponse
        }
        let expectedOrigin = Self.origin(of: configuration.baseURL)
        let actualOrigin = Self.origin(of: responseURL)
        guard expectedOrigin == actualOrigin else {
            throw SyncTransportError.redirected(
                expectedOrigin: expectedOrigin,
                actualOrigin: actualOrigin
            )
        }
    }

    private static func validate(
        _ configuration: URLSessionSyncTransportConfiguration
    ) throws {
        let scheme = configuration.baseURL.scheme?.lowercased()
        let validScheme = scheme == "https"
            || (configuration.allowsInsecureTransportForTesting && scheme == "http")
        guard validScheme,
              configuration.baseURL.host != nil,
              configuration.baseURL.user == nil,
              configuration.baseURL.password == nil,
              configuration.baseURL.query == nil,
              configuration.baseURL.fragment == nil,
              configuration.timeout > 0,
              configuration.timeout.isFinite,
              configuration.maximumRequestBytes > 0,
              configuration.maximumResponseBytes > 0,
              isValidHeaderValue(configuration.userAgent),
              !configuration.userAgent.isEmpty,
              configuration.userAgent.utf8.count <= 500
        else {
            throw SyncTransportError.invalidConfiguration(
                "Sync transport requires an absolute HTTPS base URL and positive safety limits."
            )
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { (32 ... 126).contains($0) }
    }

    private static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host):\(url.port ?? defaultPort)"
    }
}

protocol SyncHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private final class URLSessionHTTPDataLoader: @unchecked Sendable, SyncHTTPDataLoading {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private final class RedirectRejectingURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
