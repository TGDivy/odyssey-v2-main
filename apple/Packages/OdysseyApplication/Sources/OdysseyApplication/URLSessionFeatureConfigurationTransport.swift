import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OdysseySync
import OdysseyTelemetry

public enum FeatureConfigurationTransportError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case network(code: Int)
    case nonHTTPResponse
    case redirected(expectedOrigin: String, actualOrigin: String)
    case responseTooLarge(maximumBytes: Int)
    case api(statusCode: Int, error: APIErrorBody)
    case invalidResponse(statusCode: Int, correlationID: String?)
}

extension FeatureConfigurationTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        case let .network(code):
            "The feature configuration request failed at the network layer "
                + "(URL error \(code))."
        case .nonHTTPResponse:
            "The feature configuration endpoint returned a non-HTTP response."
        case let .redirected(expectedOrigin, actualOrigin):
            "The feature configuration endpoint redirected from \(expectedOrigin) "
                + "to \(actualOrigin)."
        case let .responseTooLarge(maximumBytes):
            "The feature configuration response exceeded the \(maximumBytes)-byte safety limit."
        case let .api(statusCode, error):
            "The feature configuration API returned HTTP \(statusCode): \(error.code)."
        case let .invalidResponse(statusCode, correlationID):
            if let correlationID {
                "The feature configuration API returned an invalid HTTP \(statusCode) response "
                    + "(correlation \(correlationID))."
            } else {
                "The feature configuration API returned an invalid HTTP \(statusCode) response."
            }
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .network, .nonHTTPResponse:
            true
        case let .api(statusCode, error):
            error.retryable || statusCode == 429 || (500 ... 599).contains(statusCode)
        case let .invalidResponse(statusCode, _):
            (500 ... 599).contains(statusCode)
        case .invalidRequest, .redirected, .responseTooLarge:
            false
        }
    }
}

public protocol FeatureConfigurationTransport: Sendable {
    func currentConfiguration(audience: String) async throws -> FeatureConfigurationEnvelope
}

public actor URLSessionFeatureConfigurationTransport: FeatureConfigurationTransport {
    private let configuration: NativeRemoteConfiguration
    private let tokenProvider: any BearerTokenProvider
    private let loader: any FeatureConfigurationHTTPDataLoading
    private let maximumResponseBytes: Int
    private let retainedSession: URLSession?
    private let retainedDelegate: FeatureConfigurationRedirectRejectingDelegate?

    public init(
        configuration: NativeRemoteConfiguration,
        tokenProvider: any BearerTokenProvider,
        maximumResponseBytes: Int = 128 * 1_024
    ) throws {
        guard maximumResponseBytes > 0 else {
            throw FeatureConfigurationTransportError.invalidRequest(
                "The feature configuration response limit must be positive."
            )
        }
        let delegate = FeatureConfigurationRedirectRejectingDelegate()
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
        self.tokenProvider = tokenProvider
        loader = FeatureConfigurationURLSessionLoader(session: session)
        self.maximumResponseBytes = maximumResponseBytes
        retainedSession = session
        retainedDelegate = delegate
    }

    init(
        configuration: NativeRemoteConfiguration,
        tokenProvider: any BearerTokenProvider,
        maximumResponseBytes: Int = 128 * 1_024,
        loader: any FeatureConfigurationHTTPDataLoading
    ) throws {
        guard maximumResponseBytes > 0 else {
            throw FeatureConfigurationTransportError.invalidRequest(
                "The feature configuration response limit must be positive."
            )
        }
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.maximumResponseBytes = maximumResponseBytes
        self.loader = loader
        retainedSession = nil
        retainedDelegate = nil
    }

    public func currentConfiguration(
        audience: String
    ) async throws -> FeatureConfigurationEnvelope {
        guard Self.validAudience(audience) else {
            throw FeatureConfigurationTransportError.invalidRequest(
                "The feature configuration audience is invalid."
            )
        }
        let token = try await tokenProvider.validAccessToken()
        guard Self.isHeaderSafe(token),
              !token.isEmpty,
              token.utf8.count <= 16 * 1_024
        else {
            throw FeatureConfigurationTransportError.invalidRequest(
                "The bearer-token provider returned an empty or header-unsafe token."
            )
        }
        var request = URLRequest(url: try endpoint(audience: audience))
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Correlation-ID")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch let error as URLError {
            throw FeatureConfigurationTransportError.network(code: error.errorCode)
        } catch let error as FeatureConfigurationTransportError {
            throw error
        } catch {
            throw FeatureConfigurationTransportError.network(code: URLError.unknown.rawValue)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FeatureConfigurationTransportError.nonHTTPResponse
        }
        try verifyResponseOrigin(httpResponse.url)
        guard data.count <= maximumResponseBytes else {
            throw FeatureConfigurationTransportError.responseTooLarge(
                maximumBytes: maximumResponseBytes
            )
        }
        let correlationID = httpResponse.value(forHTTPHeaderField: "X-Correlation-ID")
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let envelope = try? SyncJSONCoding.makeDecoder().decode(
                APIErrorEnvelope.self,
                from: data
            ) {
                throw FeatureConfigurationTransportError.api(
                    statusCode: httpResponse.statusCode,
                    error: envelope.error
                )
            }
            throw FeatureConfigurationTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        guard httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .hasPrefix("application/json") == true
        else {
            throw FeatureConfigurationTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        do {
            return try JSONDecoder().decode(FeatureConfigurationEnvelope.self, from: data)
        } catch {
            throw FeatureConfigurationTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
    }

    private func endpoint(audience: String) throws -> URL {
        var endpoint = configuration.baseURL
        for component in ["v1", "product", "feature-configuration"] {
            endpoint.appendPathComponent(component)
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw FeatureConfigurationTransportError.invalidRequest(
                "The feature configuration endpoint URL is invalid."
            )
        }
        components.queryItems = [URLQueryItem(name: "audience", value: audience)]
        guard let url = components.url else {
            throw FeatureConfigurationTransportError.invalidRequest(
                "The feature configuration request URL could not be encoded."
            )
        }
        return url
    }

    private func verifyResponseOrigin(_ responseURL: URL?) throws {
        guard let responseURL else {
            throw FeatureConfigurationTransportError.nonHTTPResponse
        }
        let expectedOrigin = Self.origin(of: configuration.baseURL)
        let actualOrigin = Self.origin(of: responseURL)
        guard expectedOrigin == actualOrigin else {
            throw FeatureConfigurationTransportError.redirected(
                expectedOrigin: expectedOrigin,
                actualOrigin: actualOrigin
            )
        }
    }

    private static func validAudience(_ value: String) -> Bool {
        guard (3 ... 255).contains(value.count),
              let first = value.unicodeScalars.first,
              let last = value.unicodeScalars.last,
              first.isASCII,
              last.isASCII,
              CharacterSet.alphanumerics.contains(first),
              CharacterSet.alphanumerics.contains(last)
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            $0.isASCII
                && (CharacterSet.alphanumerics.contains($0)
                    || ".-".unicodeScalars.contains($0))
        }
    }

    private static func isHeaderSafe(_ value: String) -> Bool {
        value.utf8.allSatisfy { (32 ... 126).contains($0) }
    }

    private static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(host):\(url.port ?? defaultPort)"
    }
}

protocol FeatureConfigurationHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private final class FeatureConfigurationURLSessionLoader:
    @unchecked Sendable,
    FeatureConfigurationHTTPDataLoading
{
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private final class FeatureConfigurationRedirectRejectingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
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
