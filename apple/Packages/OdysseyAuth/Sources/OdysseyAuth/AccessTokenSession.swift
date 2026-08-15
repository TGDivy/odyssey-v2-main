import Foundation
import OdysseyDomain
import OdysseySync

public enum AuthSessionError: Error, Equatable, Sendable {
    case notEnrolled
    case refreshCredentialExpired
    case invalidServerResponse
    case deviceMismatch
}

public protocol AuthClient: Sendable {
    func createAppleChallenge(deviceID: UUIDv7) async throws -> AppleChallengeResponse
    func exchangeAppleIdentity(_ request: AppleExchangeRequest) async throws -> DeviceEnrollmentResponse
    func refreshAccessToken(_ request: AccessTokenRefreshRequest) async throws -> AccessTokenResponse
}

public actor AccessTokenSession: BearerTokenProvider {
    private let vault: any CredentialVault
    private let client: any AuthClient
    private let clock: @Sendable () -> Date
    private let refreshLeeway: TimeInterval
    private var cachedToken: CachedAccessToken?

    public init(
        vault: any CredentialVault,
        client: any AuthClient,
        refreshLeeway: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard refreshLeeway >= 0, refreshLeeway.isFinite else {
            throw AuthSessionError.invalidServerResponse
        }
        self.vault = vault
        self.client = client
        self.refreshLeeway = refreshLeeway
        self.clock = clock
    }

    public func install(_ enrollment: DeviceEnrollmentResponse) async throws {
        guard enrollment.tokenType == "Bearer",
              !enrollment.accessToken.isEmpty,
              (32 ... 512).contains(enrollment.refreshCredential.count),
              enrollment.accessTokenExpiresAt > clock(),
              enrollment.refreshCredentialExpiresAt > clock()
        else {
            throw AuthSessionError.invalidServerResponse
        }
        let deviceID = try await vault.loadOrCreateDeviceID()
        guard enrollment.device.deviceID == deviceID else {
            throw AuthSessionError.deviceMismatch
        }
        let credential = try StoredRefreshCredential(
            deviceID: deviceID,
            value: enrollment.refreshCredential,
            expiresAt: enrollment.refreshCredentialExpiresAt
        )
        try await vault.storeRefreshCredential(credential)
        cachedToken = CachedAccessToken(
            value: enrollment.accessToken,
            expiresAt: enrollment.accessTokenExpiresAt
        )
    }

    public func validAccessToken() async throws -> String {
        let now = clock()
        if let cachedToken,
           cachedToken.expiresAt.timeIntervalSince(now) > refreshLeeway
        {
            return cachedToken.value
        }
        guard let credential = try await vault.refreshCredential() else {
            throw AuthSessionError.notEnrolled
        }
        guard credential.expiresAt > now else {
            cachedToken = nil
            try await vault.clearRefreshCredential()
            throw AuthSessionError.refreshCredentialExpired
        }
        let response = try await client.refreshAccessToken(
            AccessTokenRefreshRequest(
                deviceID: credential.deviceID,
                refreshCredential: credential.value
            )
        )
        guard response.tokenType == "Bearer",
              !response.accessToken.isEmpty,
              response.accessTokenExpiresAt > now
        else {
            throw AuthSessionError.invalidServerResponse
        }
        let token = CachedAccessToken(
            value: response.accessToken,
            expiresAt: response.accessTokenExpiresAt
        )
        cachedToken = token
        return token.value
    }

    public func invalidateAccessToken() {
        cachedToken = nil
    }

    public func clearEnrollment() async throws {
        cachedToken = nil
        try await vault.clearRefreshCredential()
    }
}

private struct CachedAccessToken: Sendable {
    let value: String
    let expiresAt: Date
}
