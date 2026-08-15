import Foundation
@testable import OdysseyAuth
import OdysseyDomain
import OdysseySync
import Testing

private let authFixtureDate = Date(timeIntervalSince1970: 1_786_752_000)

@Test
func authContractsEncodeBackendSnakeCaseShape() throws {
    let challengeID = try authIdentifier(1)
    let deviceID = try authIdentifier(2)
    let request = try AppleExchangeRequest(
        challengeID: challengeID,
        deviceID: deviceID,
        nonce: String(repeating: "n", count: 43),
        identityToken: String(repeating: "t", count: 120),
        displayName: "Synthetic iPhone",
        platform: .iOS,
        appVersion: "1.0-test"
    )
    let encoded = try SyncJSONCoding.makeEncoder().encode(request)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["challenge_id"] as? String == challengeID.description)
    #expect(object["device_id"] as? String == deviceID.description)
    #expect(object["identity_token"] as? String == String(repeating: "t", count: 120))
    #expect(object["platform"] as? String == "ios")
    #expect(object["app_version"] as? String == "1.0-test")
}

@Test
func accessTokenSessionStoresRefreshAndCoalescesActorRefreshes() async throws {
    let deviceID = try authIdentifier(10)
    let vault = MemoryCredentialVault(deviceID: deviceID)
    let client = FixtureAuthClient(
        response: AccessTokenResponse(
            accessToken: "refreshed-access-token",
            accessTokenExpiresAt: authFixtureDate.addingTimeInterval(600)
        )
    )
    let session = try AccessTokenSession(
        vault: vault,
        client: client,
        refreshLeeway: 60,
        clock: { authFixtureDate }
    )
    try await session.install(
        DeviceEnrollmentResponse(
            accessToken: "initial-access-token",
            accessTokenExpiresAt: authFixtureDate.addingTimeInterval(30),
            refreshCredential: String(repeating: "r", count: 64),
            refreshCredentialExpiresAt: authFixtureDate.addingTimeInterval(86_400),
            device: deviceSummary(deviceID: deviceID)
        )
    )

    async let first = session.validAccessToken()
    async let second = session.validAccessToken()
    #expect(try await first == "refreshed-access-token")
    #expect(try await second == "refreshed-access-token")
    #expect(await client.refreshCount() == 1)
    #expect(try await vault.refreshCredential()?.deviceID == deviceID)
}

@Test
func accessTokenSessionDeletesExpiredRefreshCredential() async throws {
    let deviceID = try authIdentifier(20)
    let vault = MemoryCredentialVault(deviceID: deviceID)
    try await vault.storeRefreshCredential(
        StoredRefreshCredential(
            deviceID: deviceID,
            value: String(repeating: "r", count: 64),
            expiresAt: authFixtureDate.addingTimeInterval(-1)
        )
    )
    let session = try AccessTokenSession(
        vault: vault,
        client: FixtureAuthClient(
            response: AccessTokenResponse(
                accessToken: "unused",
                accessTokenExpiresAt: authFixtureDate.addingTimeInterval(600)
            )
        ),
        clock: { authFixtureDate }
    )

    await #expect(throws: AuthSessionError.refreshCredentialExpired) {
        try await session.validAccessToken()
    }
    #expect(try await vault.refreshCredential() == nil)
}

private actor MemoryCredentialVault: CredentialVault {
    private let deviceID: UUIDv7
    private var storedCredential: StoredRefreshCredential?

    init(deviceID: UUIDv7) {
        self.deviceID = deviceID
    }

    func loadOrCreateDeviceID() async throws -> UUIDv7 {
        deviceID
    }

    func refreshCredential() async throws -> StoredRefreshCredential? {
        storedCredential
    }

    func storeRefreshCredential(_ credential: StoredRefreshCredential) async throws {
        guard credential.deviceID == deviceID else {
            throw CredentialVaultError.deviceMismatch
        }
        storedCredential = credential
    }

    func clearRefreshCredential() async throws {
        storedCredential = nil
    }

    func clearAll() async throws {
        storedCredential = nil
    }
}

private actor FixtureAuthClient: AuthClient {
    private let response: AccessTokenResponse
    private var count = 0

    init(response: AccessTokenResponse) {
        self.response = response
    }

    func createAppleChallenge(deviceID: UUIDv7) async throws -> AppleChallengeResponse {
        AppleChallengeResponse(
            challengeID: try authIdentifier(30),
            nonce: String(repeating: "n", count: 43),
            expiresAt: authFixtureDate.addingTimeInterval(300)
        )
    }

    func exchangeAppleIdentity(_ request: AppleExchangeRequest) async throws -> DeviceEnrollmentResponse {
        throw AuthSessionError.invalidServerResponse
    }

    func refreshAccessToken(_ request: AccessTokenRefreshRequest) async throws -> AccessTokenResponse {
        count += 1
        return response
    }

    func refreshCount() -> Int {
        count
    }
}

private func deviceSummary(deviceID: UUIDv7) -> DeviceSummary {
    DeviceSummary(
        deviceID: deviceID,
        displayName: "Synthetic iPhone",
        platform: .iOS,
        appVersion: "1.0-test",
        status: .active,
        enrolledAt: authFixtureDate,
        lastAuthenticatedAt: authFixtureDate,
        lastSeenAt: authFixtureDate
    )
}

private func authIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
