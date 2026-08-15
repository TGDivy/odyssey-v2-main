import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OdysseyData
import OdysseyDomain
import OdysseySync

public enum LifeModelTransportError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case network(code: Int)
    case nonHTTPResponse
    case redirected(expectedOrigin: String, actualOrigin: String)
    case responseTooLarge(maximumBytes: Int)
    case api(statusCode: Int, error: APIErrorBody)
    case invalidResponse(statusCode: Int, correlationID: String?)
}

extension LifeModelTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            message
        case let .network(code):
            "The orientation request failed at the network layer (URL error \(code))."
        case .nonHTTPResponse:
            "The orientation endpoint returned a non-HTTP response."
        case let .redirected(expectedOrigin, actualOrigin):
            "The orientation endpoint redirected from \(expectedOrigin) to \(actualOrigin)."
        case let .responseTooLarge(maximumBytes):
            "The orientation response exceeded the \(maximumBytes)-byte safety limit."
        case let .api(statusCode, error):
            "The orientation API returned HTTP \(statusCode): \(error.code)."
        case let .invalidResponse(statusCode, correlationID):
            if let correlationID {
                "The orientation API returned an invalid HTTP \(statusCode) response (correlation \(correlationID))."
            } else {
                "The orientation API returned an invalid HTTP \(statusCode) response."
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

public protocol LifeModelTransport: Sendable {
    func submit(_ command: LifeModelAcceptanceCommand) async throws -> LifeModelRevisionReceipt
    func orientation(asOf: Date?) async throws -> CurrentOrientationResponse
    func history(kind: LifeModelKind, limit: Int) async throws -> LifeModelHistoryResponse
}

public actor URLSessionLifeModelTransport: LifeModelTransport {
    private let configuration: NativeRemoteConfiguration
    private let tokenProvider: any BearerTokenProvider
    private let loader: any LifeModelHTTPDataLoading
    private let maximumResponseBytes: Int
    private let retainedSession: URLSession?
    private let retainedDelegate: LifeModelRedirectRejectingDelegate?

    public init(
        configuration: NativeRemoteConfiguration,
        tokenProvider: any BearerTokenProvider,
        maximumResponseBytes: Int = 4 * 1_024 * 1_024
    ) throws {
        guard maximumResponseBytes > 0 else {
            throw LifeModelTransportError.invalidRequest(
                "The orientation response limit must be positive."
            )
        }
        let delegate = LifeModelRedirectRejectingDelegate()
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
        loader = LifeModelURLSessionLoader(session: session)
        self.maximumResponseBytes = maximumResponseBytes
        retainedSession = session
        retainedDelegate = delegate
    }

    init(
        configuration: NativeRemoteConfiguration,
        tokenProvider: any BearerTokenProvider,
        loader: any LifeModelHTTPDataLoading,
        maximumResponseBytes: Int = 4 * 1_024 * 1_024
    ) throws {
        guard maximumResponseBytes > 0 else {
            throw LifeModelTransportError.invalidRequest(
                "The orientation response limit must be positive."
            )
        }
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        self.loader = loader
        self.maximumResponseBytes = maximumResponseBytes
        retainedSession = nil
        retainedDelegate = nil
    }

    public func submit(
        _ command: LifeModelAcceptanceCommand
    ) async throws -> LifeModelRevisionReceipt {
        try validateQueuedCommand(command)
        return try await send(
            method: "POST",
            path: Self.path(for: command.kind),
            queryItems: [],
            body: command.requestBody
        )
    }

    public func orientation(asOf: Date? = nil) async throws -> CurrentOrientationResponse {
        let queryItems = asOf.map {
            [URLQueryItem(name: "as_of", value: SyncJSONCoding.dateString($0))]
        } ?? []
        return try await send(
            method: "GET",
            path: ["v1", "seasons", "orientation"],
            queryItems: queryItems,
            body: nil
        )
    }

    public func history(
        kind: LifeModelKind,
        limit: Int = 200
    ) async throws -> LifeModelHistoryResponse {
        guard (1 ... 200).contains(limit) else {
            throw LifeModelTransportError.invalidRequest(
                "Orientation history limits must be between 1 and 200."
            )
        }
        return try await send(
            method: "GET",
            path: ["v1", "seasons", "history"],
            queryItems: [
                URLQueryItem(name: "kind", value: kind.rawValue),
                URLQueryItem(name: "limit", value: String(limit)),
            ],
            body: nil
        )
    }

    private func send<Response: Decodable>(
        method: String,
        path: [String],
        queryItems: [URLQueryItem],
        body: Data?
    ) async throws -> Response {
        let token = try await tokenProvider.validAccessToken()
        guard Self.isHeaderSafe(token),
              !token.isEmpty,
              token.utf8.count <= 16 * 1_024
        else {
            throw LifeModelTransportError.invalidRequest(
                "The bearer-token provider returned an empty or header-unsafe token."
            )
        }
        var request = URLRequest(url: try endpoint(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Correlation-ID")
        if body != nil {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await loader.data(for: request)
        } catch let error as URLError {
            throw LifeModelTransportError.network(code: error.errorCode)
        } catch let error as LifeModelTransportError {
            throw error
        } catch {
            throw LifeModelTransportError.network(code: URLError.unknown.rawValue)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LifeModelTransportError.nonHTTPResponse
        }
        try verifyResponseOrigin(httpResponse.url)
        guard data.count <= maximumResponseBytes else {
            throw LifeModelTransportError.responseTooLarge(maximumBytes: maximumResponseBytes)
        }
        let correlationID = httpResponse.value(forHTTPHeaderField: "X-Correlation-ID")
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let envelope = try? SyncJSONCoding.makeDecoder().decode(
                APIErrorEnvelope.self,
                from: data
            ) {
                throw LifeModelTransportError.api(
                    statusCode: httpResponse.statusCode,
                    error: envelope.error
                )
            }
            throw LifeModelTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        guard httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .hasPrefix("application/json") == true
        else {
            throw LifeModelTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
        do {
            return try SyncJSONCoding.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw LifeModelTransportError.invalidResponse(
                statusCode: httpResponse.statusCode,
                correlationID: correlationID
            )
        }
    }

    private func validateQueuedCommand(
        _ command: LifeModelAcceptanceCommand
    ) throws {
        guard command.requestBody.count <= 1_024 * 1_024,
              let request = try? SyncJSONCoding.makeDecoder().decode(
                  [String: JSONValue].self,
                  from: command.requestBody
              ),
              let document = try? SyncJSONCoding.makeDecoder().decode(
                  [String: JSONValue].self,
                  from: command.document
              ),
              Self.uuid(request["event_id"]) == command.eventID,
              Self.uuid(request["device_id"]) != nil,
              Self.matchesOptionalUUID(
                  request["expected_current_version_id"],
                  expected: command.expectedCurrentVersionID
              ),
              Self.string(request["acceptance_method"])
                == command.acceptanceMethod.rawValue
        else {
            throw LifeModelTransportError.invalidRequest(
                "A queued orientation command must match its immutable metadata."
            )
        }
        let documentKey: String
        switch command.kind {
        case .charter:
            documentKey = "charter"
        case .lifeStage:
            documentKey = "life_stage"
        case .season:
            documentKey = "season"
        }
        guard Self.object(request[documentKey]) == document,
              let metadata = Self.object(document["metadata"]),
              Self.uuid(metadata["id"]) == command.versionID,
              Self.integer(metadata["revision"]) == command.versionNumber
        else {
            throw LifeModelTransportError.invalidRequest(
                "A queued orientation document must match its immutable version metadata."
            )
        }
        switch command.kind {
        case .charter:
            guard Self.uuid(document["charter_id"]) == command.logicalID,
                  Self.integer(document["version_number"]) == command.versionNumber,
                  Self.matchesOptionalUUID(
                      document["supersedes_version_id"],
                      expected: command.expectedCurrentVersionID
                  ),
                  Self.date(document["accepted_at"]) == command.acceptedAt
            else {
                throw LifeModelTransportError.invalidRequest(
                    "A queued Charter request does not match its immutable command."
                )
            }
        case .lifeStage:
            guard Self.uuid(document["stage_id"]) == command.logicalID,
                  Self.date(request["accepted_at"]) == command.acceptedAt
            else {
                throw LifeModelTransportError.invalidRequest(
                    "A queued life-stage request does not match its immutable command."
                )
            }
        case .season:
            guard Self.uuid(request["season_id"]) == command.logicalID,
                  Self.matchesOptionalUUID(
                      document["supersedes_season_id"],
                      expected: command.expectedCurrentVersionID
                  ),
                  Self.date(request["accepted_at"]) == command.acceptedAt
            else {
                throw LifeModelTransportError.invalidRequest(
                    "A queued season request does not match its immutable command."
                )
            }
        }
    }

    private func endpoint(path: [String], queryItems: [URLQueryItem]) throws -> URL {
        var endpoint = configuration.baseURL
        for component in path {
            endpoint.appendPathComponent(component)
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LifeModelTransportError.invalidRequest(
                "The orientation endpoint URL is invalid."
            )
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw LifeModelTransportError.invalidRequest(
                "The orientation request URL could not be encoded."
            )
        }
        return url
    }

    private func verifyResponseOrigin(_ responseURL: URL?) throws {
        guard let responseURL else {
            throw LifeModelTransportError.nonHTTPResponse
        }
        let expectedOrigin = Self.origin(of: configuration.baseURL)
        let actualOrigin = Self.origin(of: responseURL)
        guard expectedOrigin == actualOrigin else {
            throw LifeModelTransportError.redirected(
                expectedOrigin: expectedOrigin,
                actualOrigin: actualOrigin
            )
        }
    }

    private static func path(for kind: LifeModelKind) -> [String] {
        switch kind {
        case .charter:
            ["v1", "seasons", "charter", "revisions"]
        case .lifeStage:
            ["v1", "seasons", "life-stage", "revisions"]
        case .season:
            ["v1", "seasons", "revisions"]
        }
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case let .object(object) = value else { return nil }
        return object
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case let .string(string) = value else { return nil }
        return string
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max)
        else {
            return nil
        }
        return Int(number)
    }

    private static func uuid(_ value: JSONValue?) -> UUIDv7? {
        guard let value = string(value), let uuid = UUID(uuidString: value) else {
            return nil
        }
        return try? UUIDv7(validating: uuid)
    }

    private static func matchesOptionalUUID(
        _ value: JSONValue?,
        expected: UUIDv7?
    ) -> Bool {
        guard let value else { return expected == nil }
        if case .null = value {
            return expected == nil
        }
        return uuid(value) == expected && expected != nil
    }

    private static func date(_ value: JSONValue?) -> Date? {
        string(value).flatMap(SyncJSONCoding.parseDate)
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

protocol LifeModelHTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

private final class LifeModelURLSessionLoader: @unchecked Sendable, LifeModelHTTPDataLoading {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

private final class LifeModelRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
