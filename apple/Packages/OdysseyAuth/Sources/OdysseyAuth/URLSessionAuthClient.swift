import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OdysseyDomain
import OdysseySync

public struct URLSessionAuthClientConfiguration: Sendable {
    public let baseURL: URL
    public let timeout: TimeInterval
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let userAgent: String
    public let allowsInsecureTransportForTesting: Bool

    public init(
        baseURL: URL,
        timeout: TimeInterval = 30,
        maximumRequestBytes: Int = 32 * 1_024,
        maximumResponseBytes: Int = 1 * 1_024 * 1_024,
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

public enum AuthTransportError: Error, Equatable, Sendable {
    case invalidConfiguration
    case requestTooLarge
    case network(code: Int)
    case nonHTTPResponse
    case redirected
    case responseTooLarge
    case api(statusCode: Int, error: APIErrorBody)
    case invalidResponse(statusCode: Int, correlationID: String?)
}

public actor URLSessionAuthClient: AuthClient {
    private let configuration: URLSessionAuthClientConfiguration
    private let loader: any AuthHTTPDataLoading
    private let retainedSession: URLSession?
    private let retainedDelegate: AuthRedirectRejectingDelegate?

    public init(configuration: URLSessionAuthClientConfiguration) throws {
        try Self.validate(configuration)
        let delegate = AuthRedirectRejectingDelegate()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.configuration = configuration
        loader = URLSessionAuthHTTPDataLoader(session: session)
        retainedSession = session
        retainedDelegate = delegate
    }

    init(
        configuration: URLSessionAuthClientConfiguration,
        loader: any AuthHTTPDataLoading
    ) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        self.loader = loader
        retainedSession = nil
        retainedDelegate = nil
    }

    public func createAppleChallenge(
        deviceID: UUIDv7
    ) async throws -> AppleChallengeResponse {
        try await post(
            path: ["v1", "auth", "apple", "challenges"],
            body: AppleChallengeRequest(deviceID: deviceID)
        )
    }

    public func exchangeAppleIdentity(
        _ request: AppleExchangeRequest
    ) async throws -> DeviceEnrollmentResponse {
        try await post(
            path: ["v1", "auth", "apple", "exchange"],
            body: request
        )
    }

    public func refreshAccessToken(
        _ request: AccessTokenRefreshRequest
    ) async throws -> AccessTokenResponse {
        try await post(
            path: ["v1", "auth", "token", "refresh"],
            body: request
        )
    }

    public func exchangeRecoveryCredential(
        _ request: RecoveryExchangeRequest
    ) async throws -> DeviceEnrollmentResponse {
        try await post(
            path: ["v1", "auth", "recovery", "exchange"],
            body: request
        )
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: [String],
        body: Body
    ) async throws -> Response {
        let encodedBody = try SyncJSONCoding.makeEncoder().encode(body)
        guard encodedBody.count <= configuration.maximumRequestBytes else {
            throw AuthTransportError.requestTooLarge
        }
        var request = URLRequest(url: try endpoint(path: path))
        request.httpMethod = "POST"
        request.httpBody = encodedBody
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Correlation-ID")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch let error as URLError {
            throw AuthTransportError.network(code: error.errorCode)
        } catch let error as AuthTransportError {
            throw error
        } catch {
            throw AuthTransportError.network(code: URLError.unknown.rawValue)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthTransportError.nonHTTPResponse
        }
        guard Self.origin(of: httpResponse.url) == Self.origin(of: configuration.baseURL) else {
            throw AuthTransportError.redirected
        }
        guard data.count <= configuration.maximumResponseBytes else {
            throw AuthTransportError.responseTooLarge
        }
        let correlationID = httpResponse.value(forHTTPHeaderField: "X-Correlation-ID")
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let envelope = try? SyncJSONCoding.makeDecoder().decode(
                APIErrorEnvelope.self,
                from: data
            ) {
                throw AuthTransportError.api(
                    statusCode: httpResponse.statusCode,
                    error: envelope.error
                )
            }
            throw AuthTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        guard httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .hasPrefix("application/json") == true
        else {
            throw AuthTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        do {
            return try SyncJSONCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw AuthTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
    }

    private func endpoint(path: [String]) throws -> URL {
        var endpoint = configuration.baseURL
        for component in path {
            endpoint.appendPathComponent(component)
        }
        guard let components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ), let url = components.url else {
            throw AuthTransportError.invalidConfiguration
        }
        return url
    }

    private static func validate(
        _ configuration: URLSessionAuthClientConfiguration
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
              !configuration.userAgent.isEmpty,
              configuration.userAgent.utf8.count <= 500,
              configuration.userAgent.utf8.allSatisfy({ (32 ... 126).contains($0) })
        else {
            throw AuthTransportError.invalidConfiguration
        }
    }

    private static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host):\(url.port ?? defaultPort)"
    }
}

protocol AuthHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private final class URLSessionAuthHTTPDataLoader: @unchecked Sendable, AuthHTTPDataLoading {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private final class AuthRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
