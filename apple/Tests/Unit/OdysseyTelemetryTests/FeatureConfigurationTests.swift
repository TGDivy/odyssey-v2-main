import Foundation
import OdysseyDomain
import OdysseyTelemetry
import Testing

#if canImport(CryptoKit)
import CryptoKit
#endif

private let featureIssuedAt = Date(timeIntervalSince1970: 1_786_881_600)

private func featureUUID() throws -> UUIDv7 {
    try UUIDv7(
        validating: #require(
            UUID(uuidString: "018f22d2-8a80-7000-8000-000000000001")
        )
    )
}

private func featurePayload(
    rolloutBasisPoints: Int = 10_000,
    environment: FeatureConfigurationEnvironment = .test
) throws -> FeatureConfigurationPayload {
    try FeatureConfigurationPayload(
        configurationID: featureUUID(),
        version: 1,
        environment: environment,
        audience: "com.example.odyssey.app",
        issuedAt: featureIssuedAt,
        notBefore: featureIssuedAt,
        expiresAt: featureIssuedAt.addingTimeInterval(7 * 24 * 60 * 60),
        flags: [
            try FeatureFlagRule(
                key: .proactiveNotifications,
                variant: "enabled",
                rolloutBasisPoints: rolloutBasisPoints,
                assignmentSalt: "synthetic-1"
            ),
        ]
    )
}

private struct ExpectedSignatureVerifier: FeatureConfigurationSignatureVerifying {
    let expectedSignature: Data
    let expectedPayload: Data
    let expectedPublicKey: Data

    func isValidSignature(_ signature: Data, for payload: Data, publicKey: Data) -> Bool {
        signature == expectedSignature
            && payload == expectedPayload
            && publicKey == expectedPublicKey
    }
}

@Test
func featureRegistryMirrorsSafeDefaults() {
    #expect(FeatureFlagRegistry.definitions.count == FeatureFlagKey.allCases.count)
    #expect(FeatureFlagRegistry.safeDefaults[.captureTelemetryQuestion] == "enabled")
    #expect(FeatureFlagRegistry.safeDefaults[.tomorrowMapTelemetryQuestion] == "enabled")
    #expect(FeatureFlagRegistry.safeDefaults[.weeklyProductReview] == "enabled")
    #expect(FeatureFlagRegistry.safeDefaults[.proactiveNotifications] == "disabled")
}

@Test
func featurePayloadRejectsUnsupportedAndDuplicateRules() throws {
    let unsupported = try FeatureFlagRule(
        key: .weeklyProductReview,
        variant: "unsupported",
        rolloutBasisPoints: 10_000,
        assignmentSalt: "synthetic-1"
    )
    #expect(throws: FeatureConfigurationValidationError.unsupportedVariant(.weeklyProductReview)) {
        try FeatureConfigurationPayload(
            configurationID: featureUUID(),
            version: 1,
            environment: .test,
            audience: "com.example.odyssey.app",
            issuedAt: featureIssuedAt,
            notBefore: featureIssuedAt,
            expiresAt: featureIssuedAt.addingTimeInterval(60),
            flags: [unsupported]
        )
    }

    let duplicate = try FeatureFlagRule(
        key: .proactiveNotifications,
        variant: "disabled",
        rolloutBasisPoints: 0,
        assignmentSalt: "synthetic-2"
    )
    #expect(throws: FeatureConfigurationValidationError.duplicateRule(.proactiveNotifications)) {
        try FeatureConfigurationPayload(
            configurationID: featureUUID(),
            version: 1,
            environment: .test,
            audience: "com.example.odyssey.app",
            issuedAt: featureIssuedAt,
            notBefore: featureIssuedAt,
            expiresAt: featureIssuedAt.addingTimeInterval(60),
            flags: [try featurePayload().flags[0], duplicate]
        )
    }
}

@Test
func featureAssignmentMatchesBackendSHA256Bucket() throws {
    let included = FeatureFlagAssignment.variants(
        for: try featurePayload(rolloutBasisPoints: 5_493),
        assignmentSubject: "synthetic-device"
    )
    let excluded = FeatureFlagAssignment.variants(
        for: try featurePayload(rolloutBasisPoints: 5_492),
        assignmentSubject: "synthetic-device"
    )
    let defaults = FeatureFlagAssignment.variants(
        for: nil,
        assignmentSubject: "synthetic-device"
    )

    #expect(included[.proactiveNotifications] == "enabled")
    #expect(excluded[.proactiveNotifications] == "disabled")
    #expect(defaults[.captureTelemetryQuestion] == "enabled")
    #expect(defaults[.proactiveNotifications] == "disabled")
}

@Test
func featureEnvelopeVerifiesBackendCanonicalPayload() throws {
    let canonicalPayload = Data(
        #"{"audience":"com.example.odyssey.app","configuration_id":"018f22d2-8a80-7000-8000-000000000001","environment":"test","expires_at":"2026-08-23T12:00:00Z","flags":[{"assignment_salt":"synthetic-1","key":"intervention.proactive_notifications","rollout_basis_points":10000,"variant":"enabled"}],"issued_at":"2026-08-16T12:00:00Z","not_before":"2026-08-16T12:00:00Z","schema_version":1,"version":1}"#.utf8
    )
    let signature = Data(repeating: 0xA5, count: 64)
    let publicKey = Data(repeating: 0x5A, count: 32)
    let envelope = try FeatureConfigurationEnvelope(
        keyID: "synthetic-key-1",
        payloadBase64: canonicalPayload.base64EncodedString(),
        payloadSHA256: SHA256Digest.hexDigest(of: canonicalPayload),
        signatureBase64: signature.base64EncodedString()
    )
    let verifier = try FeatureConfigurationVerifier(
        expectedKeyID: "synthetic-key-1",
        publicKey: publicKey,
        expectedEnvironment: .test,
        expectedAudience: "com.example.odyssey.app",
        signatureVerifier: ExpectedSignatureVerifier(
            expectedSignature: signature,
            expectedPayload: canonicalPayload,
            expectedPublicKey: publicKey
        )
    )

    let payload = try verifier.verify(
        envelope,
        at: featureIssuedAt.addingTimeInterval(60)
    )

    #expect(payload.configurationID.description == "018f22d2-8a80-7000-8000-000000000001")
    #expect(payload.flags.first?.key == .proactiveNotifications)
}

@Test
func featureEnvelopeRejectsDigestAndEnvironmentMismatch() throws {
    let payload = try ProductTelemetryCoding.makeEncoder().encode(featurePayload())
    let signature = Data(repeating: 0xA5, count: 64)
    let publicKey = Data(repeating: 0x5A, count: 32)
    let signatureVerifier = ExpectedSignatureVerifier(
        expectedSignature: signature,
        expectedPayload: payload,
        expectedPublicKey: publicKey
    )
    let verifier = try FeatureConfigurationVerifier(
        expectedKeyID: "synthetic-key-1",
        publicKey: publicKey,
        expectedEnvironment: .production,
        expectedAudience: "com.example.odyssey.app",
        signatureVerifier: signatureVerifier
    )
    let wrongDigest = try FeatureConfigurationEnvelope(
        keyID: "synthetic-key-1",
        payloadBase64: payload.base64EncodedString(),
        payloadSHA256: String(repeating: "0", count: 64),
        signatureBase64: signature.base64EncodedString()
    )
    let validDigest = try FeatureConfigurationEnvelope(
        keyID: "synthetic-key-1",
        payloadBase64: payload.base64EncodedString(),
        payloadSHA256: SHA256Digest.hexDigest(of: payload),
        signatureBase64: signature.base64EncodedString()
    )

    #expect(throws: FeatureConfigurationVerificationError.digestMismatch) {
        try verifier.verify(wrongDigest, at: featureIssuedAt.addingTimeInterval(60))
    }
    #expect(throws: FeatureConfigurationVerificationError.environmentMismatch) {
        try verifier.verify(validDigest, at: featureIssuedAt.addingTimeInterval(60))
    }
}

@Test
func featureDecoderRejectsUnknownFieldsAndInactivePayloads() throws {
    let unknownFieldPayload = Data(
        #"{"audience":"com.example.odyssey.app","configuration_id":"018f22d2-8a80-7000-8000-000000000001","environment":"test","expires_at":"2026-08-23T12:00:00Z","flags":[],"issued_at":"2026-08-16T12:00:00Z","not_before":"2026-08-16T12:00:00Z","schema_version":1,"unexpected":true,"version":1}"#.utf8
    )
    #expect(throws: DecodingError.self) {
        try ProductTelemetryCoding.makeDecoder().decode(
            FeatureConfigurationPayload.self,
            from: unknownFieldPayload
        )
    }

    let payload = try ProductTelemetryCoding.makeEncoder().encode(featurePayload())
    let signature = Data(repeating: 0xA5, count: 64)
    let publicKey = Data(repeating: 0x5A, count: 32)
    let envelope = try FeatureConfigurationEnvelope(
        keyID: "synthetic-key-1",
        payloadBase64: payload.base64EncodedString(),
        payloadSHA256: SHA256Digest.hexDigest(of: payload),
        signatureBase64: signature.base64EncodedString()
    )
    let verifier = try FeatureConfigurationVerifier(
        expectedKeyID: "synthetic-key-1",
        publicKey: publicKey,
        expectedEnvironment: .test,
        expectedAudience: "com.example.odyssey.app",
        signatureVerifier: ExpectedSignatureVerifier(
            expectedSignature: signature,
            expectedPayload: payload,
            expectedPublicKey: publicKey
        )
    )

    #expect(throws: FeatureConfigurationVerificationError.notYetActive) {
        try verifier.verify(envelope, at: featureIssuedAt.addingTimeInterval(-1))
    }
    #expect(throws: FeatureConfigurationVerificationError.expired) {
        try verifier.verify(envelope, at: featureIssuedAt.addingTimeInterval(7 * 24 * 60 * 60))
    }
}

#if canImport(CryptoKit)
@Test
func cryptoKitVerifierChecksRuntimeEd25519Signature() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let payload = Data("synthetic-feature-payload".utf8)
    let signature = try privateKey.signature(for: payload)

    #expect(
        CryptoKitEd25519SignatureVerifier().isValidSignature(
            signature,
            for: payload,
            publicKey: privateKey.publicKey.rawRepresentation
        )
    )
}
#endif
