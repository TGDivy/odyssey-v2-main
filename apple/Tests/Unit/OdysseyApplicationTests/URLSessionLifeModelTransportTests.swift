import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseySync
import Testing

private let lifeTransportFixtureDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func lifeModelTransportMatchesAuthenticatedAcceptanceAndHistoryRoutes() async throws {
    let command = try lifeTransportCommand(index: 1, kind: .charter)
    let envelope = try lifeTransportEnvelope(command: command)
    let policyVersion = "life-model-acceptance-policy-1.0"
    let loader = RecordingLifeModelHTTPDataLoader(
        responses: [
            "POST /root/v1/seasons/charter/revisions": LifeModelStubHTTPResponse(
                body: try SyncJSONCoding.makeEncoder().encode(
                    LifeModelRevisionReceipt(
                        version: envelope,
                        eventID: command.eventID,
                        ledgerSequence: envelope.ledgerSequence,
                        created: true,
                        warnings: [],
                        policyVersion: policyVersion
                    )
                )
            ),
            "GET /root/v1/seasons/orientation": LifeModelStubHTTPResponse(
                body: try SyncJSONCoding.makeEncoder().encode(
                    CurrentOrientationResponse(
                        asOf: lifeTransportFixtureDate,
                        charter: envelope,
                        lifeStage: nil,
                        season: nil,
                        policyVersion: policyVersion
                    )
                )
            ),
            "GET /root/v1/seasons/history": LifeModelStubHTTPResponse(
                body: try SyncJSONCoding.makeEncoder().encode(
                    LifeModelHistoryResponse(
                        kind: .charter,
                        versions: [envelope],
                        policyVersion: policyVersion
                    )
                )
            ),
        ]
    )
    let transport = try URLSessionLifeModelTransport(
        configuration: lifeTransportConfiguration(),
        tokenProvider: LifeModelFixedTokenProvider(token: "synthetic-access-token"),
        loader: loader
    )

    let receipt = try await transport.submit(command)
    let orientation = try await transport.orientation(asOf: lifeTransportFixtureDate)
    let history = try await transport.history(kind: .charter, limit: 25)

    #expect(receipt.version.eventID == command.eventID)
    #expect(orientation.charter?.versionID == command.versionID)
    #expect(history.versions.map(\.versionID) == [command.versionID])
    let requests = await loader.requests()
    #expect(requests.count == 3)
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-token"
    })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Accept") == "application/json"
    })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "User-Agent") == "Odyssey/1.0-test (ios; staging)"
    })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "X-Correlation-ID")?.isEmpty == false
    })
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[0].httpBody == command.requestBody)
    #expect(
        requests[0].value(forHTTPHeaderField: "Content-Type")
            == "application/json; charset=utf-8"
    )
    let orientationQuery = try #require(
        requests[1].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    #expect(requests[1].httpMethod == "GET")
    #expect(
        orientationQuery.queryItems?.contains(
            URLQueryItem(
                name: "as_of",
                value: SyncJSONCoding.dateString(lifeTransportFixtureDate)
            )
        ) == true
    )
    let historyQuery = try #require(
        requests[2].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    #expect(historyQuery.queryItems?.contains(URLQueryItem(name: "kind", value: "charter")) == true)
    #expect(historyQuery.queryItems?.contains(URLQueryItem(name: "limit", value: "25")) == true)
}

@Test
func lifeModelTransportPreservesStableAPIErrorAndRejectsRedirects() async throws {
    let errorBody = APIErrorBody(
        code: "LIFE_MODEL_CURRENT_VERSION_CONFLICT",
        message: "Review the accepted current version.",
        retryable: false,
        correlationID: "correlation-1"
    )
    let conflictLoader = RecordingLifeModelHTTPDataLoader(
        responses: [
            "POST /v1/seasons/revisions": LifeModelStubHTTPResponse(
                statusCode: 409,
                body: try SyncJSONCoding.makeEncoder().encode(
                    APIErrorEnvelope(error: errorBody)
                )
            ),
        ]
    )
    let conflictTransport = try URLSessionLifeModelTransport(
        configuration: lifeTransportConfiguration(rootPath: false),
        tokenProvider: LifeModelFixedTokenProvider(token: "synthetic-access-token"),
        loader: conflictLoader
    )
    let command = try lifeTransportCommand(index: 2, kind: .season)

    await #expect(throws: LifeModelTransportError.api(statusCode: 409, error: errorBody)) {
        try await conflictTransport.submit(command)
    }

    let redirectLoader = RecordingLifeModelHTTPDataLoader(
        responses: [
            "GET /v1/seasons/history": LifeModelStubHTTPResponse(
                body: try SyncJSONCoding.makeEncoder().encode(
                    LifeModelHistoryResponse(
                        kind: .lifeStage,
                        versions: [],
                        policyVersion: "life-model-acceptance-policy-1.0"
                    )
                ),
                responseURL: URL(string: "https://redirected.example.test/v1/seasons/history")!
            ),
        ]
    )
    let redirectTransport = try URLSessionLifeModelTransport(
        configuration: lifeTransportConfiguration(rootPath: false),
        tokenProvider: LifeModelFixedTokenProvider(token: "synthetic-access-token"),
        loader: redirectLoader
    )
    await #expect(throws: LifeModelTransportError.redirected(
        expectedOrigin: "https://api.example.test:443",
        actualOrigin: "https://redirected.example.test:443"
    )) {
        try await redirectTransport.history(kind: .lifeStage, limit: 10)
    }
}

@Test
func lifeModelTransportRefusesDivergentQueuedMetadataBeforeNetworkUse() async throws {
    let valid = try lifeTransportCommand(index: 3, kind: .lifeStage)
    var request = try SyncJSONCoding.makeDecoder().decode(
        [String: JSONValue].self,
        from: valid.requestBody
    )
    request["event_id"] = .string(try lifeTransportIdentifier(999).description)
    let divergent = try LifeModelAcceptanceCommand(
        eventID: valid.eventID,
        kind: valid.kind,
        versionID: valid.versionID,
        logicalID: valid.logicalID,
        versionNumber: valid.versionNumber,
        expectedCurrentVersionID: valid.expectedCurrentVersionID,
        acceptanceMethod: valid.acceptanceMethod,
        acceptedAt: valid.acceptedAt,
        requestBody: SyncJSONCoding.makeEncoder().encode(request),
        document: valid.document,
        createdAt: valid.createdAt
    )
    let loader = RecordingLifeModelHTTPDataLoader(responses: [:])
    let transport = try URLSessionLifeModelTransport(
        configuration: lifeTransportConfiguration(rootPath: false),
        tokenProvider: LifeModelFixedTokenProvider(token: "synthetic-access-token"),
        loader: loader
    )

    await #expect(throws: LifeModelTransportError.invalidRequest(
        "A queued orientation command must match its immutable metadata."
    )) {
        try await transport.submit(divergent)
    }
    #expect(await loader.requests().isEmpty)
}

private struct LifeModelFixedTokenProvider: BearerTokenProvider {
    let token: String

    func validAccessToken() async throws -> String {
        token
    }
}

private struct LifeModelStubHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
    let responseURL: URL?

    init(statusCode: Int = 200, body: Data, responseURL: URL? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.responseURL = responseURL
    }
}

private actor RecordingLifeModelHTTPDataLoader: LifeModelHTTPDataLoading {
    private let responses: [String: LifeModelStubHTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [String: LifeModelStubHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequests.append(request)
        let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
        guard let stub = responses[key], let requestURL = request.url else {
            throw URLError(.resourceUnavailable)
        }
        let response = HTTPURLResponse(
            url: stub.responseURL ?? requestURL,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "X-Correlation-ID": "correlation-1",
            ]
        )!
        return (stub.body, response)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private func lifeTransportConfiguration(
    rootPath: Bool = true
) throws -> NativeRemoteConfiguration {
    try NativeRemoteConfiguration(
        baseURL: URL(
            string: rootPath
                ? "https://api.example.test/root"
                : "https://api.example.test"
        )!,
        environment: .staging,
        platform: .iOS,
        appVersion: "1.0-test"
    )
}

private func lifeTransportCommand(
    index: Int,
    kind: LifeModelKind
) throws -> LifeModelAcceptanceCommand {
    let eventID = try lifeTransportIdentifier(index * 10 + 1)
    let versionID = try lifeTransportIdentifier(index * 10 + 2)
    let logicalID = try lifeTransportIdentifier(index * 10 + 3)
    let deviceID = try lifeTransportIdentifier(900)
    var document: [String: JSONValue] = [
        "metadata": .object([
            "id": .string(versionID.description),
            "revision": .number(1),
        ]),
        "title": .string("Synthetic \(kind.rawValue)"),
    ]
    var request: [String: JSONValue] = [
        "event_id": .string(eventID.description),
        "device_id": .string(deviceID.description),
        "expected_current_version_id": .null,
        "acceptance_method": .string(LifeModelAcceptanceMethod.ownerAuthored.rawValue),
    ]
    switch kind {
    case .charter:
        document["charter_id"] = .string(logicalID.description)
        document["version_number"] = .number(1)
        document["supersedes_version_id"] = .null
        document["accepted_at"] = .string(SyncJSONCoding.dateString(lifeTransportFixtureDate))
        request["charter"] = .object(document)
    case .lifeStage:
        document["stage_id"] = .string(logicalID.description)
        request["accepted_at"] = .string(SyncJSONCoding.dateString(lifeTransportFixtureDate))
        request["life_stage"] = .object(document)
    case .season:
        document["supersedes_season_id"] = .null
        request["season_id"] = .string(logicalID.description)
        request["accepted_at"] = .string(SyncJSONCoding.dateString(lifeTransportFixtureDate))
        request["season"] = .object(document)
    }
    return try LifeModelAcceptanceCommand(
        eventID: eventID,
        kind: kind,
        versionID: versionID,
        logicalID: logicalID,
        versionNumber: 1,
        expectedCurrentVersionID: nil,
        acceptanceMethod: .ownerAuthored,
        acceptedAt: lifeTransportFixtureDate,
        requestBody: SyncJSONCoding.makeEncoder().encode(request),
        document: SyncJSONCoding.makeEncoder().encode(document),
        createdAt: lifeTransportFixtureDate
    )
}

private func lifeTransportEnvelope(
    command: LifeModelAcceptanceCommand
) throws -> LifeModelVersionEnvelope {
    LifeModelVersionEnvelope(
        kind: command.kind,
        versionID: command.versionID,
        logicalID: command.logicalID,
        versionNumber: command.versionNumber,
        acceptanceSequence: 1,
        eventID: command.eventID,
        ledgerSequence: 1,
        supersedesVersionID: command.expectedCurrentVersionID,
        status: nil,
        acceptanceMethod: command.acceptanceMethod,
        acceptedAt: command.acceptedAt,
        contentHash: String(repeating: "a", count: 64),
        document: try SyncJSONCoding.makeDecoder().decode(
            [String: JSONValue].self,
            from: command.document
        )
    )
}

private func lifeTransportIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
