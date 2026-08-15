import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OdysseyData
import OdysseyDomain
@testable import OdysseySync
import Testing

private let transportFixtureDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func urlSessionTransportMatchesAuthenticatedBackendRoutes() async throws {
    let deviceID = try transportIdentifier(1)
    let operationID = try transportIdentifier(2)
    let entityID = try transportIdentifier(3)
    let conflictID = try transportIdentifier(4)
    let responseBodies = try transportResponseBodies(
        deviceID: deviceID,
        operationID: operationID,
        conflictID: conflictID
    )
    let loader = RecordingSyncHTTPDataLoader(responses: responseBodies)
    let transport = try URLSessionSyncTransport(
        configuration: URLSessionSyncTransportConfiguration(
            baseURL: URL(string: "https://api.example.test/root")!,
            userAgent: "OdysseyTests/1"
        ),
        tokenProvider: FixedBearerTokenProvider(token: "synthetic-access-token"),
        loader: loader
    )
    let operation = try SyncOperation(
        operationID: operationID,
        deviceSequence: 1,
        entityType: "capture",
        entityID: entityID,
        mutationType: .create,
        payload: ["text": .string("offline")],
        createdAt: transportFixtureDate
    )
    let pushRequest = try SyncPushRequest(
        deviceID: deviceID,
        baseCursor: SyncCursor("c_0"),
        operations: [operation]
    )
    _ = try await transport.push(pushRequest, batchIdempotencyKey: "batch-1")
    _ = try await transport.pull(after: SyncCursor("c_0"), limit: 50, deviceID: deviceID)
    let diagnosticsInput = try SyncDeviceDiagnosticsInput(
        deviceCursor: SyncCursor("c_0"),
        operationsQueued: 1,
        oldestUnsyncedOperationAt: transportFixtureDate,
        attachmentBacklog: 0
    )
    _ = try await transport.reportDiagnostics(
        deviceID: deviceID,
        diagnostics: diagnosticsInput
    )
    _ = try await transport.diagnostics()
    _ = try await transport.conflicts(status: .pending, limit: 100)
    let resolutionRequest = try SyncConflictResolutionRequest(
        operationID: try transportIdentifier(5),
        deviceID: deviceID,
        deviceSequence: 2,
        expectedCurrentRevision: 1,
        strategy: .keepCurrent,
        createdAt: transportFixtureDate
    )
    _ = try await transport.resolveConflict(
        conflictID: conflictID,
        request: resolutionRequest
    )

    let requests = await loader.requests()
    #expect(requests.count == 6)
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access-token"
    })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Accept") == "application/json"
    })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "User-Agent") == "OdysseyTests/1"
    })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "X-Correlation-ID")?.isEmpty == false
    })

    let push = requests[0]
    #expect(push.httpMethod == "POST")
    #expect(push.url?.path == "/root/v1/sync/push")
    #expect(push.value(forHTTPHeaderField: "Idempotency-Key") == "batch-1")
    #expect(push.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")
    let encodedPush = try #require(push.httpBody)
    let pushObject = try #require(
        JSONSerialization.jsonObject(with: encodedPush) as? [String: Any]
    )
    #expect(pushObject["device_id"] as? String == deviceID.description)

    let pull = requests[1]
    let pullComponents = try #require(
        pull.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    #expect(pull.httpMethod == "GET")
    #expect(pullComponents.path == "/root/v1/sync/changes")
    #expect(pullComponents.queryItems?.contains(URLQueryItem(name: "cursor", value: "c_0")) == true)
    #expect(pullComponents.queryItems?.contains(URLQueryItem(name: "limit", value: "50")) == true)
    #expect(pull.value(forHTTPHeaderField: "X-Odyssey-Device-ID") == deviceID.description)
    #expect(pull.httpBody == nil)

    #expect(requests[2].httpMethod == "PUT")
    #expect(requests[2].url?.path == "/root/v1/sync/devices/\(deviceID)/diagnostics")
    #expect(requests[3].url?.path == "/root/v1/sync/diagnostics")
    #expect(requests[4].url?.absoluteString.contains("status=pending") == true)
    #expect(requests[5].url?.path == "/root/v1/sync/conflicts/\(conflictID)/resolve")
}

@Test
func urlSessionTransportDecodesStableAPIErrorWithoutBodyLeakage() async throws {
    let body = APIErrorBody(
        code: "SYNC_PULL_DISABLED",
        message: "Sync pulls are temporarily disabled.",
        retryable: true,
        correlationID: "correlation-1",
        details: ["retry_after_seconds": .number(30)]
    )
    let loader = RecordingSyncHTTPDataLoader(
        responses: [
            "GET /root/v1/sync/diagnostics": StubHTTPResponse(
                statusCode: 503,
                body: try SyncJSONCoding.makeEncoder().encode(APIErrorEnvelope(error: body))
            ),
        ]
    )
    let transport = try URLSessionSyncTransport(
        configuration: URLSessionSyncTransportConfiguration(
            baseURL: URL(string: "https://api.example.test/root")!
        ),
        tokenProvider: FixedBearerTokenProvider(token: "synthetic-access-token"),
        loader: loader
    )

    await #expect(throws: SyncTransportError.api(statusCode: 503, error: body)) {
        try await transport.diagnostics()
    }
}

@Test
func urlSessionTransportRejectsCrossOriginResponsesAndPlainHTTP() async throws {
    let diagnostics = try transportDiagnostics(deviceID: transportIdentifier(10))
    let loader = RecordingSyncHTTPDataLoader(
        responses: [
            "GET /v1/sync/diagnostics": StubHTTPResponse(
                body: try SyncJSONCoding.makeEncoder().encode(diagnostics),
                responseURL: URL(string: "https://redirected.example.test/v1/sync/diagnostics")!
            ),
        ]
    )
    let transport = try URLSessionSyncTransport(
        configuration: URLSessionSyncTransportConfiguration(
            baseURL: URL(string: "https://api.example.test")!
        ),
        tokenProvider: FixedBearerTokenProvider(token: "synthetic-access-token"),
        loader: loader
    )
    await #expect(throws: SyncTransportError.redirected(
        expectedOrigin: "https://api.example.test:443",
        actualOrigin: "https://redirected.example.test:443"
    )) {
        try await transport.diagnostics()
    }
    #expect(throws: SyncTransportError.invalidConfiguration(
        "Sync transport requires an absolute HTTPS base URL and positive safety limits."
    )) {
        try URLSessionSyncTransport(
            configuration: URLSessionSyncTransportConfiguration(
                baseURL: URL(string: "http://api.example.test")!
            ),
            tokenProvider: FixedBearerTokenProvider(token: "synthetic-access-token")
        )
    }
}

private struct FixedBearerTokenProvider: BearerTokenProvider {
    let token: String

    func validAccessToken() async throws -> String {
        token
    }
}

private struct StubHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
    let responseURL: URL?

    init(statusCode: Int = 200, body: Data, responseURL: URL? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.responseURL = responseURL
    }
}

private actor RecordingSyncHTTPDataLoader: SyncHTTPDataLoading {
    private let responses: [String: StubHTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [String: StubHTTPResponse]) {
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

private func transportResponseBodies(
    deviceID: UUIDv7,
    operationID: UUIDv7,
    conflictID: UUIDv7
) throws -> [String: StubHTTPResponse] {
    let encoder = SyncJSONCoding.makeEncoder()
    let accepted = AcceptedOperation(
        operationID: operationID,
        canonicalRevision: 1,
        serverChangeID: 1,
        mergeResult: "created"
    )
    let diagnostics = try transportDiagnostics(deviceID: deviceID)
    return [
        "POST /root/v1/sync/push": StubHTTPResponse(
            body: try encoder.encode(
                SyncPushResponse(
                    accepted: [accepted],
                    nextCursor: SyncCursor("c_1"),
                    serverTime: transportFixtureDate,
                    serverSchemaVersion: 1,
                    minimumClientSchemaVersion: 1
                )
            )
        ),
        "GET /root/v1/sync/changes": StubHTTPResponse(
            body: try encoder.encode(
                SyncPullResponse(
                    changes: [],
                    nextCursor: SyncCursor("c_0"),
                    hasMore: false,
                    serverTime: transportFixtureDate,
                    serverSchemaVersion: 1,
                    minimumClientSchemaVersion: 1
                )
            )
        ),
        "PUT /root/v1/sync/devices/\(deviceID)/diagnostics": StubHTTPResponse(
            body: try encoder.encode(diagnostics.devices[0])
        ),
        "GET /root/v1/sync/diagnostics": StubHTTPResponse(
            body: try encoder.encode(diagnostics)
        ),
        "GET /root/v1/sync/conflicts": StubHTTPResponse(
            body: try encoder.encode(
                SyncConflictListResponse(
                    conflicts: [],
                    pendingCount: 0,
                    serverTime: transportFixtureDate
                )
            )
        ),
        "POST /root/v1/sync/conflicts/\(conflictID)/resolve": StubHTTPResponse(
            body: try encoder.encode(
                SyncConflictResolutionResponse(
                    resolutionID: try transportIdentifier(20),
                    conflictID: conflictID,
                    status: "resolved",
                    strategy: .keepCurrent,
                    acceptedOperation: accepted,
                    nextCursor: SyncCursor("c_1"),
                    serverTime: transportFixtureDate,
                    serverSchemaVersion: 1
                )
            )
        ),
    ]
}

private func transportDiagnostics(deviceID: UUIDv7) throws -> SyncDiagnosticsResponse {
    SyncDiagnosticsResponse(
        serverTime: transportFixtureDate,
        serverCursor: try SyncCursor("c_1"),
        serverSchemaVersion: 1,
        minimumClientSchemaVersion: 1,
        pendingConflicts: 0,
        pendingAttachmentUploads: 0,
        pendingOutboxJobs: 0,
        syncPushEnabled: true,
        syncPullEnabled: true,
        devices: [
            SyncDeviceDiagnostics(
                deviceID: deviceID,
                clientSchemaVersion: 1,
                schemaCompatibility: .compatible,
                lastSuccessfulPushAt: transportFixtureDate,
                lastSuccessfulPullAt: transportFixtureDate,
                operationsQueued: 0,
                oldestUnsyncedOperationAt: nil,
                attachmentBacklog: 0,
                lastDeviceSequence: 1,
                deviceCursor: try SyncCursor("c_1"),
                serverCursor: try SyncCursor("c_1"),
                clockSkewSeconds: 0,
                diagnosticsReportedAt: transportFixtureDate,
                diagnosticsStale: false
            ),
        ],
        repair: SyncRepairOptions(
            projectionRebuildAvailable: true,
            projectionRebuildCommand: "rebuild",
            integrityCheckCommand: "check"
        )
    )
}

private func transportIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
