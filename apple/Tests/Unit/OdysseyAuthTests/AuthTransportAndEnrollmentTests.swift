import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OdysseyAuth
import OdysseyDomain
import OdysseySync
import Testing

private let enrollmentFixtureDate = Date(timeIntervalSince1970: 1_786_752_000)

@Test
func authHTTPClientMatchesChallengeExchangeAndRefreshRoutes() async throws {
    let deviceID = try enrollmentIdentifier(1)
    let challengeID = try enrollmentIdentifier(2)
    let enrollment = enrollmentResponse(deviceID: deviceID)
    let loader = RecordingAuthHTTPDataLoader(
        responses: [
            "POST /root/v1/auth/apple/challenges": AuthStubResponse(
                body: try SyncJSONCoding.makeEncoder().encode(
                    AppleChallengeResponse(
                        challengeID: challengeID,
                        nonce: String(repeating: "n", count: 43),
                        expiresAt: enrollmentFixtureDate.addingTimeInterval(300)
                    )
                )
            ),
            "POST /root/v1/auth/apple/exchange": AuthStubResponse(
                body: try SyncJSONCoding.makeEncoder().encode(enrollment)
            ),
            "POST /root/v1/auth/token/refresh": AuthStubResponse(
                body: try SyncJSONCoding.makeEncoder().encode(
                    AccessTokenResponse(
                        accessToken: "refreshed-token",
                        accessTokenExpiresAt: enrollmentFixtureDate.addingTimeInterval(600)
                    )
                )
            ),
        ]
    )
    let client = try URLSessionAuthClient(
        configuration: URLSessionAuthClientConfiguration(
            baseURL: URL(string: "https://api.example.test/root")!,
            userAgent: "OdysseyAuthTests/1"
        ),
        loader: loader
    )
    let challenge = try await client.createAppleChallenge(deviceID: deviceID)
    _ = try await client.exchangeAppleIdentity(
        AppleExchangeRequest(
            challengeID: challenge.challengeID,
            deviceID: deviceID,
            nonce: challenge.nonce,
            identityToken: String(repeating: "t", count: 120),
            displayName: "Synthetic iPhone",
            platform: .iOS,
            appVersion: "1.0-test"
        )
    )
    _ = try await client.refreshAccessToken(
        AccessTokenRefreshRequest(
            deviceID: deviceID,
            refreshCredential: String(repeating: "r", count: 64)
        )
    )

    let requests = await loader.requests()
    #expect(requests.map { $0.url?.path } == [
        "/root/v1/auth/apple/challenges",
        "/root/v1/auth/apple/exchange",
        "/root/v1/auth/token/refresh",
    ])
    #expect(requests.allSatisfy { $0.httpMethod == "POST" })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Authorization") == nil
    })
    #expect(requests.allSatisfy {
        $0.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8"
    })
    let exchangeBody = try #require(requests[1].httpBody)
    let exchangeObject = try #require(
        JSONSerialization.jsonObject(with: exchangeBody) as? [String: Any]
    )
    #expect(exchangeObject["nonce"] as? String == String(repeating: "n", count: 43))
    #expect(exchangeObject["identity_token"] as? String == String(repeating: "t", count: 120))
}

@Test
func authHTTPClientDecodesRedactedErrorsAndRejectsHTTP() async throws {
    let errorBody = APIErrorBody(
        code: "AUTH_MODE_DISABLED",
        message: "Sign in with Apple is disabled.",
        retryable: false,
        correlationID: "auth-correlation"
    )
    let loader = RecordingAuthHTTPDataLoader(
        responses: [
            "POST /v1/auth/apple/challenges": AuthStubResponse(
                statusCode: 409,
                body: try SyncJSONCoding.makeEncoder().encode(
                    APIErrorEnvelope(error: errorBody)
                )
            ),
        ]
    )
    let client = try URLSessionAuthClient(
        configuration: URLSessionAuthClientConfiguration(
            baseURL: URL(string: "https://api.example.test")!
        ),
        loader: loader
    )
    await #expect(throws: AuthTransportError.api(statusCode: 409, error: errorBody)) {
        try await client.createAppleChallenge(deviceID: enrollmentIdentifier(3))
    }
    #expect(throws: AuthTransportError.invalidConfiguration) {
        try URLSessionAuthClient(
            configuration: URLSessionAuthClientConfiguration(
                baseURL: URL(string: "http://api.example.test")!
            )
        )
    }
}

@Test
func appleEnrollmentKeepsRawNonceForBackendAndInstallsCredential() async throws {
    let deviceID = try enrollmentIdentifier(10)
    let challenge = AppleChallengeResponse(
        challengeID: try enrollmentIdentifier(11),
        nonce: String(repeating: "raw-nonce-", count: 4),
        expiresAt: enrollmentFixtureDate.addingTimeInterval(300)
    )
    let vault = EnrollmentMemoryVault(deviceID: deviceID)
    let client = EnrollmentFixtureAuthClient(
        challenge: challenge,
        enrollment: enrollmentResponse(deviceID: deviceID)
    )
    let tokenSession = try AccessTokenSession(
        vault: vault,
        client: client,
        clock: { enrollmentFixtureDate }
    )
    let authorizer = await MainActor.run {
        EnrollmentFixtureAuthorizer(
            credential: try! AppleAuthorizationCredential(
                identityToken: String(repeating: "i", count: 120)
            )
        )
    }
    let coordinator = AppleEnrollmentCoordinator(
        vault: vault,
        client: client,
        tokenSession: tokenSession,
        authorizer: authorizer,
        clock: { enrollmentFixtureDate }
    )
    _ = try await coordinator.enroll(
        metadata: DeviceEnrollmentMetadata(
            displayName: "Synthetic iPhone",
            platform: .iOS,
            appVersion: "1.0-test"
        )
    )

    let exchangeRequest = try #require(await client.exchangeRequest())
    #expect(exchangeRequest.challengeID == challenge.challengeID)
    #expect(exchangeRequest.deviceID == deviceID)
    #expect(exchangeRequest.nonce == challenge.nonce)
    #expect(exchangeRequest.identityToken == String(repeating: "i", count: 120))
    #expect(try await tokenSession.validAccessToken() == "initial-access-token")
    #expect(try await vault.refreshCredential()?.deviceID == deviceID)
}

@Test
func appleNonceUsesBackendExpectedSHA256AndExpiredChallengeFailsClosed() async throws {
    #expect(AppleNonce.hashed("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let deviceID = try enrollmentIdentifier(20)
    let vault = EnrollmentMemoryVault(deviceID: deviceID)
    let client = EnrollmentFixtureAuthClient(
        challenge: AppleChallengeResponse(
            challengeID: try enrollmentIdentifier(21),
            nonce: String(repeating: "n", count: 43),
            expiresAt: enrollmentFixtureDate.addingTimeInterval(-1)
        ),
        enrollment: enrollmentResponse(deviceID: deviceID)
    )
    let session = try AccessTokenSession(
        vault: vault,
        client: client,
        clock: { enrollmentFixtureDate }
    )
    let authorizer = await MainActor.run {
        EnrollmentFixtureAuthorizer(
            credential: try! AppleAuthorizationCredential(
                identityToken: String(repeating: "i", count: 120)
            )
        )
    }
    let coordinator = AppleEnrollmentCoordinator(
        vault: vault,
        client: client,
        tokenSession: session,
        authorizer: authorizer,
        clock: { enrollmentFixtureDate }
    )
    await #expect(throws: AppleEnrollmentError.challengeExpired) {
        try await coordinator.enroll(
            metadata: DeviceEnrollmentMetadata(
                displayName: "Synthetic iPhone",
                platform: .iOS,
                appVersion: "1.0-test"
            )
        )
    }
    #expect(await authorizer.callCount() == 0)
}

private struct AuthStubResponse: Sendable {
    let statusCode: Int
    let body: Data

    init(statusCode: Int = 200, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

private actor RecordingAuthHTTPDataLoader: AuthHTTPDataLoading {
    private let responses: [String: AuthStubResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [String: AuthStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequests.append(request)
        let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
        guard let stub = responses[key], let url = request.url else {
            throw URLError(.resourceUnavailable)
        }
        return (
            stub.body,
            HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json; charset=utf-8",
                    "X-Correlation-ID": "auth-correlation",
                ]
            )!
        )
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private actor EnrollmentMemoryVault: CredentialVault {
    private let deviceID: UUIDv7
    private var credential: StoredRefreshCredential?

    init(deviceID: UUIDv7) {
        self.deviceID = deviceID
    }

    func loadOrCreateDeviceID() async throws -> UUIDv7 {
        deviceID
    }

    func refreshCredential() async throws -> StoredRefreshCredential? {
        credential
    }

    func storeRefreshCredential(_ credential: StoredRefreshCredential) async throws {
        guard credential.deviceID == deviceID else {
            throw CredentialVaultError.deviceMismatch
        }
        self.credential = credential
    }

    func clearRefreshCredential() async throws {
        credential = nil
    }

    func clearAll() async throws {
        credential = nil
    }
}

private actor EnrollmentFixtureAuthClient: AuthClient {
    private let challenge: AppleChallengeResponse
    private let enrollment: DeviceEnrollmentResponse
    private var capturedExchangeRequest: AppleExchangeRequest?

    init(
        challenge: AppleChallengeResponse,
        enrollment: DeviceEnrollmentResponse
    ) {
        self.challenge = challenge
        self.enrollment = enrollment
    }

    func createAppleChallenge(deviceID: UUIDv7) async throws -> AppleChallengeResponse {
        challenge
    }

    func exchangeAppleIdentity(_ request: AppleExchangeRequest) async throws -> DeviceEnrollmentResponse {
        capturedExchangeRequest = request
        return enrollment
    }

    func refreshAccessToken(_ request: AccessTokenRefreshRequest) async throws -> AccessTokenResponse {
        AccessTokenResponse(
            accessToken: "refreshed-access-token",
            accessTokenExpiresAt: enrollmentFixtureDate.addingTimeInterval(600)
        )
    }

    func exchangeRequest() -> AppleExchangeRequest? {
        capturedExchangeRequest
    }
}

@MainActor
private final class EnrollmentFixtureAuthorizer: AppleAuthorizationPerforming {
    private let credential: AppleAuthorizationCredential
    private var count = 0

    init(credential: AppleAuthorizationCredential) {
        self.credential = credential
    }

    func authorize(
        challenge: AppleChallengeResponse
    ) async throws -> AppleAuthorizationCredential {
        count += 1
        return credential
    }

    func callCount() -> Int {
        count
    }
}

private func enrollmentResponse(deviceID: UUIDv7) -> DeviceEnrollmentResponse {
    DeviceEnrollmentResponse(
        accessToken: "initial-access-token",
        accessTokenExpiresAt: enrollmentFixtureDate.addingTimeInterval(600),
        refreshCredential: String(repeating: "r", count: 64),
        refreshCredentialExpiresAt: enrollmentFixtureDate.addingTimeInterval(86_400),
        device: DeviceSummary(
            deviceID: deviceID,
            displayName: "Synthetic iPhone",
            platform: .iOS,
            appVersion: "1.0-test",
            status: .active,
            enrolledAt: enrollmentFixtureDate,
            lastAuthenticatedAt: enrollmentFixtureDate,
            lastSeenAt: enrollmentFixtureDate
        )
    )
}

private func enrollmentIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
