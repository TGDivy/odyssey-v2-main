import Foundation
@testable import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let refreshIssuedAt = Date(timeIntervalSince1970: 1_786_881_600)
private let refreshNow = refreshIssuedAt.addingTimeInterval(60)
private let refreshPublicKey = Data(repeating: 0x5A, count: 32)

private struct RefreshSignatureVerifier: FeatureConfigurationSignatureVerifying {
    func isValidSignature(_ signature: Data, for _: Data, publicKey: Data) -> Bool {
        signature.count == 64 && publicKey == refreshPublicKey
    }
}

private actor StubFeatureConfigurationTransport: FeatureConfigurationTransport {
    let envelope: FeatureConfigurationEnvelope
    private var audiences: [String] = []

    init(envelope: FeatureConfigurationEnvelope) {
        self.envelope = envelope
    }

    func currentConfiguration(audience: String) async throws -> FeatureConfigurationEnvelope {
        audiences.append(audience)
        return envelope
    }

    func requestedAudiences() -> [String] {
        audiences
    }
}

@Test
func featureRefreshVerifiesCachesAndResolvesAssignments() async throws {
    let fixture = try FeatureRefreshFixture()
    defer { fixture.remove() }
    let transport = StubFeatureConfigurationTransport(envelope: try fixture.envelope())
    let coordinator = FeatureConfigurationRefreshCoordinator(
        cache: fixture.store,
        transport: transport,
        audience: "com.example.odyssey.app",
        assignmentSubject: "synthetic-device"
    )

    let refreshed = try await coordinator.refresh()
    let current = try await coordinator.current()

    #expect(refreshed.source == .verifiedCache)
    #expect(refreshed.payload?.version == 1)
    #expect(refreshed.assignments[.proactiveNotifications] == "enabled")
    #expect(current == refreshed)
    #expect(await transport.requestedAudiences() == ["com.example.odyssey.app"])
    #expect(try fixture.store.integrityReport().cachedFeatureConfigurationCount == 1)
}

private struct FeatureRefreshFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-feature-refresh-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let verifier = try FeatureConfigurationVerifier(
            expectedKeyID: "synthetic-key-1",
            publicKey: refreshPublicKey,
            expectedEnvironment: .test,
            expectedAudience: "com.example.odyssey.app",
            signatureVerifier: RefreshSignatureVerifier()
        )
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: directory.appendingPathComponent("odyssey.sqlite"),
                deviceID: try UUIDv7(validating: UUID(
                    uuidString: "018f3e1b-7c90-7abc-8def-000000000001"
                )!),
                preMigrationBackupDirectory: directory,
                featureConfigurationVerifier: verifier,
                clock: { refreshNow }
            )
        )
    }

    func envelope() throws -> FeatureConfigurationEnvelope {
        let payload = try FeatureConfigurationPayload(
            configurationID: try UUIDv7(validating: UUID(
                uuidString: "018f3e1b-7c90-7abc-8def-000000000002"
            )!),
            version: 1,
            environment: .test,
            audience: "com.example.odyssey.app",
            issuedAt: refreshIssuedAt,
            notBefore: refreshIssuedAt,
            expiresAt: refreshIssuedAt.addingTimeInterval(7 * 24 * 60 * 60),
            flags: [
                try FeatureFlagRule(
                    key: .proactiveNotifications,
                    variant: "enabled",
                    rolloutBasisPoints: 10_000,
                    assignmentSalt: "synthetic-refresh-1"
                ),
            ]
        )
        let document = try ProductTelemetryCoding.makeEncoder().encode(payload)
        return try FeatureConfigurationEnvelope(
            keyID: "synthetic-key-1",
            payloadBase64: document.base64EncodedString(),
            payloadSHA256: SHA256Digest.hexDigest(of: document),
            signatureBase64: Data(repeating: 1, count: 64).base64EncodedString()
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
