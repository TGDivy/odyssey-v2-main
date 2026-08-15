import Foundation
import OdysseyData
import OdysseyDomain

public enum AppleEnrollmentError: Error, Equatable, Sendable {
    case invalidMetadata
    case invalidChallenge
    case challengeExpired
    case invalidIdentityToken
    case unavailable
    case busy
    case cancelled
    case stateMismatch
}

public struct DeviceEnrollmentMetadata: Codable, Hashable, Sendable {
    public let displayName: String
    public let platform: DevicePlatform
    public let appVersion: String

    public init(
        displayName: String,
        platform: DevicePlatform,
        appVersion: String
    ) throws {
        guard (1 ... 100).contains(displayName.count),
              displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines),
              (1 ... 100).contains(appVersion.count),
              appVersion == appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw AppleEnrollmentError.invalidMetadata
        }
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
    }
}

public struct AppleAuthorizationCredential: Hashable, Sendable {
    public let identityToken: String

    public init(identityToken: String) throws {
        guard (100 ... 16_384).contains(identityToken.count),
              identityToken.utf8.allSatisfy({ (33 ... 126).contains($0) })
        else {
            throw AppleEnrollmentError.invalidIdentityToken
        }
        self.identityToken = identityToken
    }
}

public enum AppleNonce {
    public static func hashed(_ rawNonce: String) -> String {
        SHA256Digest.hexDigest(of: Data(rawNonce.utf8))
    }
}

public protocol AppleAuthorizationPerforming: Sendable {
    @MainActor
    func authorize(
        challenge: AppleChallengeResponse
    ) async throws -> AppleAuthorizationCredential
}

public actor AppleEnrollmentCoordinator {
    private let vault: any CredentialVault
    private let client: any AuthClient
    private let tokenSession: AccessTokenSession
    private let authorizer: any AppleAuthorizationPerforming
    private let clock: @Sendable () -> Date

    public init(
        vault: any CredentialVault,
        client: any AuthClient,
        tokenSession: AccessTokenSession,
        authorizer: any AppleAuthorizationPerforming,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.vault = vault
        self.client = client
        self.tokenSession = tokenSession
        self.authorizer = authorizer
        self.clock = clock
    }

    @discardableResult
    public func enroll(
        metadata: DeviceEnrollmentMetadata
    ) async throws -> DeviceEnrollmentResponse {
        let deviceID = try await vault.loadOrCreateDeviceID()
        let challenge = try await client.createAppleChallenge(deviceID: deviceID)
        guard challenge.nonce.count >= 32,
              challenge.nonce.count <= 200,
              challenge.nonce == challenge.nonce.trimmingCharacters(in: .whitespacesAndNewlines),
              challenge.expiresAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw AppleEnrollmentError.invalidChallenge
        }
        guard challenge.expiresAt > clock() else {
            throw AppleEnrollmentError.challengeExpired
        }
        let credential = try await authorizer.authorize(challenge: challenge)
        guard challenge.expiresAt > clock() else {
            throw AppleEnrollmentError.challengeExpired
        }
        let request = try AppleExchangeRequest(
            challengeID: challenge.challengeID,
            deviceID: deviceID,
            nonce: challenge.nonce,
            identityToken: credential.identityToken,
            displayName: metadata.displayName,
            platform: metadata.platform,
            appVersion: metadata.appVersion
        )
        let enrollment = try await client.exchangeAppleIdentity(request)
        guard enrollment.device.deviceID == deviceID else {
            throw AuthSessionError.deviceMismatch
        }
        try await tokenSession.install(enrollment)
        return enrollment
    }
}
