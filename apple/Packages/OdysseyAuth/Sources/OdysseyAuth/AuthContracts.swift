import Foundation
import OdysseyDomain

public enum AuthContractError: Error, Equatable, Sendable {
    case invalidField(String)
}

public enum DevicePlatform: String, Codable, Hashable, Sendable {
    case iOS = "ios"
    case iPadOS = "ipados"
    case macOS = "macos"
    case watchOS = "watchos"
    case visionOS = "visionos"
}

public enum DeviceStatus: String, Codable, Hashable, Sendable {
    case active
    case revoked
}

public enum DeviceRevocationReason: String, Codable, Hashable, Sendable {
    case compromised
    case lost
    case ownerRequest = "owner_request"
    case reinstalled
    case retired
}

public struct AppleChallengeRequest: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7

    public init(deviceID: UUIDv7) {
        self.deviceID = deviceID
    }
}

public struct AppleChallengeResponse: Codable, Hashable, Sendable {
    public let challengeID: UUIDv7
    public let nonce: String
    public let expiresAt: Date

    public init(challengeID: UUIDv7, nonce: String, expiresAt: Date) {
        self.challengeID = challengeID
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

public struct AppleExchangeRequest: Codable, Hashable, Sendable {
    public let challengeID: UUIDv7
    public let deviceID: UUIDv7
    public let nonce: String
    public let identityToken: String
    public let displayName: String
    public let platform: DevicePlatform
    public let appVersion: String

    public init(
        challengeID: UUIDv7,
        deviceID: UUIDv7,
        nonce: String,
        identityToken: String,
        displayName: String,
        platform: DevicePlatform,
        appVersion: String
    ) throws {
        try Self.validate(nonce, range: 32 ... 200, field: "nonce")
        try Self.validate(identityToken, range: 100 ... 16_384, field: "identity token")
        try Self.validate(displayName, range: 1 ... 100, field: "display name")
        try Self.validate(appVersion, range: 1 ... 100, field: "app version")
        self.challengeID = challengeID
        self.deviceID = deviceID
        self.nonce = nonce
        self.identityToken = identityToken
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
    }

    private static func validate(
        _ value: String,
        range: ClosedRange<Int>,
        field: String
    ) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              range.contains(value.count)
        else {
            throw AuthContractError.invalidField(field)
        }
    }
}

public struct DeviceSummary: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let displayName: String
    public let platform: DevicePlatform
    public let appVersion: String
    public let status: DeviceStatus
    public let enrolledAt: Date
    public let lastAuthenticatedAt: Date
    public let lastSeenAt: Date
    public let revokedAt: Date?
    public let revocationReason: DeviceRevocationReason?

    public init(
        deviceID: UUIDv7,
        displayName: String,
        platform: DevicePlatform,
        appVersion: String,
        status: DeviceStatus,
        enrolledAt: Date,
        lastAuthenticatedAt: Date,
        lastSeenAt: Date,
        revokedAt: Date? = nil,
        revocationReason: DeviceRevocationReason? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
        self.status = status
        self.enrolledAt = enrolledAt
        self.lastAuthenticatedAt = lastAuthenticatedAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
        self.revocationReason = revocationReason
    }
}

public struct DeviceEnrollmentResponse: Codable, Hashable, Sendable {
    public let tokenType: String
    public let accessToken: String
    public let accessTokenExpiresAt: Date
    public let refreshCredential: String
    public let refreshCredentialExpiresAt: Date
    public let device: DeviceSummary

    public init(
        tokenType: String = "Bearer",
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshCredential: String,
        refreshCredentialExpiresAt: Date,
        device: DeviceSummary
    ) {
        self.tokenType = tokenType
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshCredential = refreshCredential
        self.refreshCredentialExpiresAt = refreshCredentialExpiresAt
        self.device = device
    }
}

public struct AccessTokenRefreshRequest: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let refreshCredential: String

    public init(deviceID: UUIDv7, refreshCredential: String) throws {
        guard (32 ... 512).contains(refreshCredential.count),
              refreshCredential == refreshCredential.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw AuthContractError.invalidField("refresh credential")
        }
        self.deviceID = deviceID
        self.refreshCredential = refreshCredential
    }
}

public struct AccessTokenResponse: Codable, Hashable, Sendable {
    public let tokenType: String
    public let accessToken: String
    public let accessTokenExpiresAt: Date

    public init(
        tokenType: String = "Bearer",
        accessToken: String,
        accessTokenExpiresAt: Date
    ) {
        self.tokenType = tokenType
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
    }
}

public struct RecoveryExchangeRequest: Codable, Hashable, Sendable {
    public let recoveryCredential: String
    public let deviceID: UUIDv7
    public let displayName: String
    public let platform: DevicePlatform
    public let appVersion: String

    public init(
        recoveryCredential: String,
        deviceID: UUIDv7,
        displayName: String,
        platform: DevicePlatform,
        appVersion: String
    ) throws {
        guard (32 ... 512).contains(recoveryCredential.count),
              (1 ... 100).contains(displayName.count),
              (1 ... 100).contains(appVersion.count)
        else {
            throw AuthContractError.invalidField("recovery exchange")
        }
        self.recoveryCredential = recoveryCredential
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.appVersion = appVersion
    }
}

public struct DeviceListResponse: Codable, Hashable, Sendable {
    public let devices: [DeviceSummary]

    public init(devices: [DeviceSummary]) {
        self.devices = devices
    }
}

public struct DeviceRevocationRequest: Codable, Hashable, Sendable {
    public let reason: DeviceRevocationReason

    public init(reason: DeviceRevocationReason) {
        self.reason = reason
    }
}
