import Foundation
import OdysseyDomain

#if canImport(CryptoKit)
import CryptoKit
#endif

public enum FeatureFlagKey: String, Codable, CaseIterable, Sendable {
    case captureTelemetryQuestion = "product_telemetry.capture_question"
    case tomorrowMapTelemetryQuestion = "product_telemetry.tomorrow_map_question"
    case weeklyProductReview = "product_telemetry.weekly_review"
    case proactiveNotifications = "intervention.proactive_notifications"
}

public struct FeatureFlagDefinition: Hashable, Sendable {
    public let key: FeatureFlagKey
    public let owner: String
    public let purpose: String
    public let defaultVariant: String
    public let allowedVariants: [String]

    fileprivate init(
        key: FeatureFlagKey,
        owner: String,
        purpose: String,
        defaultVariant: String,
        allowedVariants: [String]
    ) {
        self.key = key
        self.owner = owner
        self.purpose = purpose
        self.defaultVariant = defaultVariant
        self.allowedVariants = allowedVariants
    }
}

public enum FeatureFlagRegistry {
    public static let version = 1

    public static let definitions: [FeatureFlagDefinition] = [
        FeatureFlagDefinition(
            key: .captureTelemetryQuestion,
            owner: "product_evaluation",
            purpose: "Kill switch for the governed payload-free capture question.",
            defaultVariant: "enabled",
            allowedVariants: ["enabled", "disabled"]
        ),
        FeatureFlagDefinition(
            key: .tomorrowMapTelemetryQuestion,
            owner: "product_evaluation",
            purpose: "Kill switch for the governed Tomorrow Map value question.",
            defaultVariant: "enabled",
            allowedVariants: ["enabled", "disabled"]
        ),
        FeatureFlagDefinition(
            key: .weeklyProductReview,
            owner: "product_evaluation",
            purpose: "Kill switch for local weekly product review generation.",
            defaultVariant: "enabled",
            allowedVariants: ["enabled", "disabled"]
        ),
        FeatureFlagDefinition(
            key: .proactiveNotifications,
            owner: "intervention_policy",
            purpose: "Edition gate that keeps proactive notifications disabled by default.",
            defaultVariant: "disabled",
            allowedVariants: ["enabled", "disabled"]
        ),
    ]

    public static func definition(for key: FeatureFlagKey) -> FeatureFlagDefinition {
        definitionsByKey[key]!
    }

    public static var safeDefaults: [FeatureFlagKey: String] {
        Dictionary(uniqueKeysWithValues: definitions.map { ($0.key, $0.defaultVariant) })
    }

    private static let definitionsByKey = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.key, $0) }
    )
}

public enum FeatureConfigurationEnvironment: String, Codable, CaseIterable, Sendable {
    case local
    case development
    case staging
    case production
    case test
}

public enum FeatureConfigurationValidationError: Error, Equatable, Sendable {
    case invalidField(String)
    case duplicateRule(FeatureFlagKey)
    case unsupportedVariant(FeatureFlagKey)
    case invalidLifetime
}

public struct FeatureFlagRule: Codable, Hashable, Sendable {
    public let key: FeatureFlagKey
    public let variant: String
    public let rolloutBasisPoints: Int
    public let assignmentSalt: String

    public init(
        key: FeatureFlagKey,
        variant: String,
        rolloutBasisPoints: Int,
        assignmentSalt: String
    ) throws {
        guard validLowercaseToken(variant, maximum: 100) else {
            throw FeatureConfigurationValidationError.invalidField("variant")
        }
        guard (0 ... 10_000).contains(rolloutBasisPoints) else {
            throw FeatureConfigurationValidationError.invalidField("rollout_basis_points")
        }
        guard validToken(assignmentSalt, maximum: 100) else {
            throw FeatureConfigurationValidationError.invalidField("assignment_salt")
        }
        self.key = key
        self.variant = variant
        self.rolloutBasisPoints = rolloutBasisPoints
        self.assignmentSalt = assignmentSalt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: container.decode(FeatureFlagKey.self, forKey: .key),
            variant: container.decode(String.self, forKey: .variant),
            rolloutBasisPoints: container.decode(Int.self, forKey: .rolloutBasisPoints),
            assignmentSalt: container.decode(String.self, forKey: .assignmentSalt)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key
        case variant
        case rolloutBasisPoints = "rollout_basis_points"
        case assignmentSalt = "assignment_salt"
    }
}

public struct FeatureConfigurationPayload: Codable, Hashable, Sendable {
    public static let maximumLifetime: TimeInterval = 90 * 24 * 60 * 60

    public let schemaVersion: Int
    public let configurationID: UUIDv7
    public let version: Int
    public let environment: FeatureConfigurationEnvironment
    public let audience: String
    public let issuedAt: Date
    public let notBefore: Date
    public let expiresAt: Date
    public let flags: [FeatureFlagRule]

    public init(
        schemaVersion: Int = 1,
        configurationID: UUIDv7,
        version: Int,
        environment: FeatureConfigurationEnvironment,
        audience: String,
        issuedAt: Date,
        notBefore: Date,
        expiresAt: Date,
        flags: [FeatureFlagRule]
    ) throws {
        guard schemaVersion == 1 else {
            throw FeatureConfigurationValidationError.invalidField("schema_version")
        }
        guard version >= 1 else {
            throw FeatureConfigurationValidationError.invalidField("version")
        }
        guard validAudience(audience) else {
            throw FeatureConfigurationValidationError.invalidField("audience")
        }
        guard validDate(issuedAt), validDate(notBefore), validDate(expiresAt) else {
            throw FeatureConfigurationValidationError.invalidField("timestamp")
        }
        guard notBefore >= issuedAt,
              expiresAt > notBefore,
              expiresAt.timeIntervalSince(notBefore) <= Self.maximumLifetime
        else {
            throw FeatureConfigurationValidationError.invalidLifetime
        }
        guard flags.count <= 50 else {
            throw FeatureConfigurationValidationError.invalidField("flags")
        }
        var seenKeys = Set<FeatureFlagKey>()
        for rule in flags {
            guard seenKeys.insert(rule.key).inserted else {
                throw FeatureConfigurationValidationError.duplicateRule(rule.key)
            }
            guard FeatureFlagRegistry.definition(for: rule.key)
                .allowedVariants.contains(rule.variant)
            else {
                throw FeatureConfigurationValidationError.unsupportedVariant(rule.key)
            }
        }
        self.schemaVersion = schemaVersion
        self.configurationID = configurationID
        self.version = version
        self.environment = environment
        self.audience = audience
        self.issuedAt = issuedAt
        self.notBefore = notBefore
        self.expiresAt = expiresAt
        self.flags = flags
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            configurationID: container.decode(UUIDv7.self, forKey: .configurationID),
            version: container.decode(Int.self, forKey: .version),
            environment: container.decode(
                FeatureConfigurationEnvironment.self,
                forKey: .environment
            ),
            audience: container.decode(String.self, forKey: .audience),
            issuedAt: container.decode(Date.self, forKey: .issuedAt),
            notBefore: container.decode(Date.self, forKey: .notBefore),
            expiresAt: container.decode(Date.self, forKey: .expiresAt),
            flags: container.decode([FeatureFlagRule].self, forKey: .flags)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case configurationID = "configuration_id"
        case version
        case environment
        case audience
        case issuedAt = "issued_at"
        case notBefore = "not_before"
        case expiresAt = "expires_at"
        case flags
    }
}

public struct FeatureConfigurationEnvelope: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let keyID: String
    public let payloadBase64: String
    public let payloadSHA256: String
    public let signatureBase64: String

    public init(
        schemaVersion: Int = 1,
        keyID: String,
        payloadBase64: String,
        payloadSHA256: String,
        signatureBase64: String
    ) throws {
        guard schemaVersion == 1 else {
            throw FeatureConfigurationValidationError.invalidField("schema_version")
        }
        guard validToken(keyID, maximum: 100) else {
            throw FeatureConfigurationValidationError.invalidField("key_id")
        }
        guard (4 ... 90_000).contains(payloadBase64.count) else {
            throw FeatureConfigurationValidationError.invalidField("payload_base64")
        }
        guard validLowercaseHexDigest(payloadSHA256) else {
            throw FeatureConfigurationValidationError.invalidField("payload_sha256")
        }
        guard (4 ... 200).contains(signatureBase64.count) else {
            throw FeatureConfigurationValidationError.invalidField("signature_base64")
        }
        self.schemaVersion = schemaVersion
        self.keyID = keyID
        self.payloadBase64 = payloadBase64
        self.payloadSHA256 = payloadSHA256
        self.signatureBase64 = signatureBase64
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(from: decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            keyID: container.decode(String.self, forKey: .keyID),
            payloadBase64: container.decode(String.self, forKey: .payloadBase64),
            payloadSHA256: container.decode(String.self, forKey: .payloadSHA256),
            signatureBase64: container.decode(String.self, forKey: .signatureBase64)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case keyID = "key_id"
        case payloadBase64 = "payload_base64"
        case payloadSHA256 = "payload_sha256"
        case signatureBase64 = "signature_base64"
    }
}

public protocol FeatureConfigurationSignatureVerifying: Sendable {
    func isValidSignature(_ signature: Data, for payload: Data, publicKey: Data) -> Bool
}

#if canImport(CryptoKit)
public struct CryptoKitEd25519SignatureVerifier: FeatureConfigurationSignatureVerifying {
    public init() {}

    public func isValidSignature(
        _ signature: Data,
        for payload: Data,
        publicKey: Data
    ) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: payload)
    }
}
#endif

public enum FeatureConfigurationVerificationError: Error, Equatable, Sendable {
    case invalidTrustAnchor
    case invalidClock
    case keyIDMismatch
    case invalidEncoding
    case invalidSize
    case digestMismatch
    case invalidSignature
    case invalidPayload
    case noncanonicalPayload
    case environmentMismatch
    case audienceMismatch
    case notYetActive
    case expired
}

public struct FeatureConfigurationVerifier: Sendable {
    private let expectedKeyID: String
    private let publicKey: Data
    private let expectedEnvironment: FeatureConfigurationEnvironment
    private let expectedAudience: String
    private let signatureVerifier: any FeatureConfigurationSignatureVerifying

    public init(
        expectedKeyID: String,
        publicKey: Data,
        expectedEnvironment: FeatureConfigurationEnvironment,
        expectedAudience: String,
        signatureVerifier: any FeatureConfigurationSignatureVerifying
    ) throws {
        guard validToken(expectedKeyID, maximum: 100),
              publicKey.count == 32,
              validAudience(expectedAudience)
        else {
            throw FeatureConfigurationVerificationError.invalidTrustAnchor
        }
        self.expectedKeyID = expectedKeyID
        self.publicKey = publicKey
        self.expectedEnvironment = expectedEnvironment
        self.expectedAudience = expectedAudience
        self.signatureVerifier = signatureVerifier
    }

    public func verify(
        _ envelope: FeatureConfigurationEnvelope,
        at date: Date
    ) throws -> FeatureConfigurationPayload {
        guard validDate(date) else {
            throw FeatureConfigurationVerificationError.invalidClock
        }
        guard envelope.keyID == expectedKeyID else {
            throw FeatureConfigurationVerificationError.keyIDMismatch
        }
        guard let payload = strictBase64Decoded(envelope.payloadBase64),
              let signature = strictBase64Decoded(envelope.signatureBase64)
        else {
            throw FeatureConfigurationVerificationError.invalidEncoding
        }
        guard payload.count <= 65_536, signature.count == 64 else {
            throw FeatureConfigurationVerificationError.invalidSize
        }
        guard SHA256Digest.hexDigest(of: payload) == envelope.payloadSHA256 else {
            throw FeatureConfigurationVerificationError.digestMismatch
        }
        guard signatureVerifier.isValidSignature(
            signature,
            for: payload,
            publicKey: publicKey
        ) else {
            throw FeatureConfigurationVerificationError.invalidSignature
        }
        let decoded: FeatureConfigurationPayload
        do {
            decoded = try ProductTelemetryCoding.makeDecoder().decode(
                FeatureConfigurationPayload.self,
                from: payload
            )
        } catch {
            throw FeatureConfigurationVerificationError.invalidPayload
        }
        guard canonicalJSON(payload) == payload else {
            throw FeatureConfigurationVerificationError.noncanonicalPayload
        }
        guard decoded.environment == expectedEnvironment else {
            throw FeatureConfigurationVerificationError.environmentMismatch
        }
        guard decoded.audience == expectedAudience else {
            throw FeatureConfigurationVerificationError.audienceMismatch
        }
        guard date >= decoded.notBefore else {
            throw FeatureConfigurationVerificationError.notYetActive
        }
        guard date < decoded.expiresAt else {
            throw FeatureConfigurationVerificationError.expired
        }
        return decoded
    }

    private func strictBase64Decoded(_ value: String) -> Data? {
        guard let decoded = Data(base64Encoded: value),
              decoded.base64EncodedString() == value
        else {
            return nil
        }
        return decoded
    }

    private func canonicalJSON(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else {
            return nil
        }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

public enum FeatureFlagAssignment {
    public static func variants(
        for payload: FeatureConfigurationPayload?,
        assignmentSubject: String
    ) -> [FeatureFlagKey: String] {
        var assignments = FeatureFlagRegistry.safeDefaults
        guard let payload else {
            return assignments
        }
        for rule in payload.flags {
            let material = "\(rule.assignmentSalt):\(rule.key.rawValue):\(assignmentSubject)"
            let digest = SHA256Digest.hexDigest(of: Data(material.utf8))
            let firstEightBytes = UInt64(digest.prefix(16), radix: 16)!
            let bucket = Int(firstEightBytes % 10_000)
            assignments[rule.key] = bucket < rule.rolloutBasisPoints
                ? rule.variant
                : FeatureFlagRegistry.definition(for: rule.key).defaultVariant
        }
        return assignments
    }

    public static func wireVariants(
        for payload: FeatureConfigurationPayload?,
        assignmentSubject: String
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: variants(
                for: payload,
                assignmentSubject: assignmentSubject
            ).map { ($0.key.rawValue, $0.value) }
        )
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys<Key>(
    from decoder: Decoder,
    allowed _: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let allowedKeys = Set(Key.allCases.map { $0.stringValue })
    guard let unknown = container.allKeys
        .map(\.stringValue)
        .filter({ !allowedKeys.contains($0) })
        .sorted()
        .first
    else {
        return
    }
    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown feature configuration field: \(unknown)"
        )
    )
}

private func validDate(_ value: Date) -> Bool {
    value.timeIntervalSinceReferenceDate.isFinite
}

private func validToken(_ value: String, maximum: Int) -> Bool {
    (1 ... maximum).contains(value.count)
        && value.unicodeScalars.allSatisfy {
            $0.isASCII
                && (CharacterSet.alphanumerics.contains($0)
                    || "._-".unicodeScalars.contains($0))
        }
}

private func validLowercaseToken(_ value: String, maximum: Int) -> Bool {
    (1 ... maximum).contains(value.count)
        && value.unicodeScalars.allSatisfy {
            $0.isASCII
                && (CharacterSet.lowercaseLetters.contains($0)
                    || CharacterSet.decimalDigits.contains($0)
                    || "._-".unicodeScalars.contains($0))
        }
}

private func validAudience(_ value: String) -> Bool {
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

private func validLowercaseHexDigest(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
}
