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
    private var refreshAttempt: RefreshAttempt?
    private var nextRefreshAttemptID = 0

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
              enrollment.accessToken.utf8.count <= 8_192,
              (32 ... 512).contains(enrollment.refreshCredential.count),
              enrollment.accessTokenExpiresAt > clock(),
              enrollment.refreshCredentialExpiresAt > clock()
        else {
            throw AuthSessionError.invalidServerResponse
        }
        cancelRefreshAttempt()
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
        if let refreshAttempt {
            return try await resolve(refreshAttempt, requestedAt: now)
        }
        nextRefreshAttemptID += 1
        let attempt = RefreshAttempt(
            id: nextRefreshAttemptID,
            task: Task { [client, vault] in
                try Task.checkCancellation()
                guard let credential = try await vault.refreshCredential() else {
                    throw AuthSessionError.notEnrolled
                }
                try Task.checkCancellation()
                let deviceID = try await vault.loadOrCreateDeviceID()
                try Task.checkCancellation()
                guard credential.deviceID == deviceID else {
                    throw AuthSessionError.deviceMismatch
                }
                guard credential.expiresAt > now else {
                    try await vault.clearRefreshCredential()
                    throw AuthSessionError.refreshCredentialExpired
                }
                let response = try await client.refreshAccessToken(
                    AccessTokenRefreshRequest(
                        deviceID: credential.deviceID,
                        refreshCredential: credential.value
                    )
                )
                try Task.checkCancellation()
                guard response.tokenType == "Bearer",
                      !response.accessToken.isEmpty,
                      response.accessToken.utf8.count <= 8_192,
                      response.accessTokenExpiresAt > now
                else {
                    throw AuthSessionError.invalidServerResponse
                }
                return CachedAccessToken(
                    value: response.accessToken,
                    expiresAt: response.accessTokenExpiresAt
                )
            }
        )
        refreshAttempt = attempt
        return try await resolve(attempt, requestedAt: now)
    }

    public func invalidateAccessToken() {
        cancelRefreshAttempt()
        cachedToken = nil
    }

    public func clearEnrollment() async throws {
        cancelRefreshAttempt()
        cachedToken = nil
        try await vault.clearRefreshCredential()
    }

    private func resolve(
        _ attempt: RefreshAttempt,
        requestedAt: Date
    ) async throws -> String {
        do {
            let token = try await attempt.task.value
            if refreshAttempt?.id == attempt.id {
                cachedToken = token
                refreshAttempt = nil
                return token.value
            }
            if let cachedToken,
               cachedToken.expiresAt.timeIntervalSince(requestedAt) > refreshLeeway
            {
                return cachedToken.value
            }
            throw CancellationError()
        } catch {
            if refreshAttempt?.id == attempt.id {
                refreshAttempt = nil
            }
            throw error
        }
    }

    private func cancelRefreshAttempt() {
        refreshAttempt?.task.cancel()
        refreshAttempt = nil
    }
}

private struct CachedAccessToken: Sendable {
    let value: String
    let expiresAt: Date
}

private struct RefreshAttempt: Sendable {
    let id: Int
    let task: Task<CachedAccessToken, Error>
}
