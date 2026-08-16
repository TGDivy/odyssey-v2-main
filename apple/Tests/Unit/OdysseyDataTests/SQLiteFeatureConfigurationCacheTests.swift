import Foundation
@testable import OdysseyData
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let featureCacheIssuedAt = Date(timeIntervalSince1970: 1_786_881_600)
private let featureCacheVerifiedAt = featureCacheIssuedAt.addingTimeInterval(60)
private let featureCachePublicKey = Data(repeating: 0x5A, count: 32)

private struct SyntheticFeatureSignatureVerifier: FeatureConfigurationSignatureVerifying {
    func isValidSignature(_ signature: Data, for _: Data, publicKey: Data) -> Bool {
        signature.count == 64 && publicKey == featureCachePublicKey
    }
}

@Test
func verifiedFeatureCacheResolvesAssignmentsAndRejectsInvalidReplacement() throws {
    let fixture = try FeatureConfigurationCacheFixture()
    defer { fixture.remove() }
    let versionOne = try fixture.envelope(version: 1, proactiveVariant: "enabled")
    let first = try fixture.store.cacheFeatureConfiguration(versionOne)
    let initialResolution = try fixture.store.resolveFeatureConfiguration(
        assignmentSubject: "synthetic-device"
    )
    let invalidVersionTwo = try FeatureConfigurationEnvelope(
        keyID: "synthetic-key-1",
        payloadBase64: try fixture.envelope(
            version: 2,
            proactiveVariant: "disabled"
        ).payloadBase64,
        payloadSHA256: String(repeating: "0", count: 64),
        signatureBase64: Data(repeating: 2, count: 64).base64EncodedString()
    )

    #expect(first.payload.version == 1)
    #expect(initialResolution.source == .verifiedCache)
    #expect(initialResolution.assignments[.proactiveNotifications] == "enabled")
    #expect(try fixture.store.integrityReport().cachedFeatureConfigurationCount == 1)
    #expect(throws: FeatureConfigurationVerificationError.digestMismatch) {
        try fixture.store.cacheFeatureConfiguration(
            invalidVersionTwo
        )
    }
    #expect(
        try fixture.store.resolveFeatureConfiguration(
            at: featureCacheVerifiedAt,
            assignmentSubject: "synthetic-device"
        ).payload?.version == 1
    )
}

@Test
func verifiedFeatureCacheRejectsRollbackInServiceAndDatabase() async throws {
    let fixture = try FeatureConfigurationCacheFixture()
    defer { fixture.remove() }
    let versionOne = try fixture.envelope(version: 1, proactiveVariant: "enabled")
    let versionTwo = try fixture.envelope(version: 2, proactiveVariant: "disabled")
    _ = try fixture.store.cacheFeatureConfiguration(versionOne)
    _ = try fixture.store.cacheFeatureConfiguration(versionTwo)

    #expect(
        throws: FeatureConfigurationCacheError.rollbackRejected(
            currentVersion: 2,
            proposedVersion: 1
        )
    ) {
        try fixture.store.cacheFeatureConfiguration(
            versionOne
        )
    }
    await #expect(throws: SQLiteLedgerError.self) {
        try await fixture.store.databasePool.write { database in
            try SQLiteSession(database: database).execute(
                "UPDATE verified_feature_configuration_cache SET version = 1"
            )
        }
    }
}

@Test
func featureCacheFallsBackForMissingExpiredInvalidAndUnconfiguredState() async throws {
    let fixture = try FeatureConfigurationCacheFixture()
    defer { fixture.remove() }
    let missing = try fixture.store.resolveFeatureConfiguration(
        assignmentSubject: "synthetic-device"
    )
    _ = try fixture.store.cacheFeatureConfiguration(
        fixture.envelope(version: 1, proactiveVariant: "enabled")
    )
    let expired = try fixture.store.resolveFeatureConfiguration(
        at: featureCacheIssuedAt.addingTimeInterval(7 * 24 * 60 * 60),
        assignmentSubject: "synthetic-device"
    )
    try await fixture.store.databasePool.write { database in
        try SQLiteSession(database: database).execute(
            """
            UPDATE verified_feature_configuration_cache
            SET version = version + 1, envelope_document = X'00'
            """
        )
    }
    let invalid = try fixture.store.resolveFeatureConfiguration(
        assignmentSubject: "synthetic-device"
    )

    #expect(missing.source == .safeDefaultsMissing)
    #expect(expired.source == .safeDefaultsInactive)
    #expect(expired.assignments[.proactiveNotifications] == "disabled")
    #expect(invalid.source == .safeDefaultsInvalid)
    #expect(invalid.assignments[.proactiveNotifications] == "disabled")
    #expect(throws: SQLiteLedgerError.self) {
        try fixture.store.integrityReport()
    }

    let unconfigured = try FeatureConfigurationCacheFixture(configureVerifier: false)
    defer { unconfigured.remove() }
    let fallback = try unconfigured.store.resolveFeatureConfiguration(
        assignmentSubject: "synthetic-device"
    )
    #expect(fallback.source == .safeDefaultsUnconfigured)
    #expect(fallback.assignments[.proactiveNotifications] == "disabled")
    #expect(
        try unconfigured.store.integrityReport().schemaVersion
            == SQLiteLedgerStore.currentSchemaVersion
    )
}

private struct FeatureConfigurationCacheFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init(configureVerifier: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-feature-configuration-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let verifier = try FeatureConfigurationVerifier(
            expectedKeyID: "synthetic-key-1",
            publicKey: featureCachePublicKey,
            expectedEnvironment: .test,
            expectedAudience: "com.example.odyssey.app",
            signatureVerifier: SyntheticFeatureSignatureVerifier()
        )
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: directory.appendingPathComponent("odyssey.sqlite"),
                deviceID: try UUIDv7(validating: UUID(
                    uuidString: "018f3e1b-7c90-7abc-8def-000000000001"
                )!),
                preMigrationBackupDirectory: directory,
                featureConfigurationVerifier: configureVerifier ? verifier : nil,
                clock: { featureCacheVerifiedAt }
            )
        )
    }

    func envelope(
        version: Int,
        proactiveVariant: String
    ) throws -> FeatureConfigurationEnvelope {
        let payload = try FeatureConfigurationPayload(
            configurationID: try UUIDv7(validating: UUID(
                uuidString: "018f3e1b-7c90-7abc-8def-\(String(format: "%012x", version))"
            )!),
            version: version,
            environment: .test,
            audience: "com.example.odyssey.app",
            issuedAt: featureCacheIssuedAt,
            notBefore: featureCacheIssuedAt,
            expiresAt: featureCacheIssuedAt.addingTimeInterval(7 * 24 * 60 * 60),
            flags: [
                try FeatureFlagRule(
                    key: .proactiveNotifications,
                    variant: proactiveVariant,
                    rolloutBasisPoints: 10_000,
                    assignmentSalt: "synthetic-cache-\(version)"
                ),
            ]
        )
        let document = try ProductTelemetryCoding.makeEncoder().encode(payload)
        return try FeatureConfigurationEnvelope(
            keyID: "synthetic-key-1",
            payloadBase64: document.base64EncodedString(),
            payloadSHA256: SHA256Digest.hexDigest(of: document),
            signatureBase64: Data(repeating: UInt8(version), count: 64).base64EncodedString()
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
