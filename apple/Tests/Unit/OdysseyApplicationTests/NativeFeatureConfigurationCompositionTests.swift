import Foundation
import OdysseyAuth
@testable import OdysseyApplication
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let compositionPublicKey = Data(repeating: 0x5A, count: 32)

private struct CompositionSignatureVerifier: FeatureConfigurationSignatureVerifying {
    func isValidSignature(_: Data, for _: Data, publicKey: Data) -> Bool {
        publicKey == compositionPublicKey
    }
}

@Test
func nativeFeatureTrustValidatesPublicKeyAndComposesRefreshServices() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-feature-composition-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let trust = try NativeFeatureConfigurationTrust(
        keyID: "synthetic-key-1",
        publicKeyBase64: compositionPublicKey.base64EncodedString(),
        environment: .staging
    )
    let local = try await NativeLocalServices.bootstrap(
        configuration: NativeLocalConfiguration(
            applicationIdentifier: "com.example.odyssey.app",
            applicationSupportDirectory: directory,
            featureConfigurationTrust: trust
        ),
        vault: CompositionMemoryVault(
            deviceID: try compositionIdentifier(1)
        ),
        featureConfigurationSignatureVerifier: CompositionSignatureVerifier()
    )
    let remote = try NativeRemoteServices(
        localServices: local,
        configuration: try NativeRemoteConfiguration(
            baseURL: URL(string: "https://api.example.test")!,
            environment: .staging,
            platform: .iOS,
            appVersion: "1.0-test"
        )
    )
    let coordinator = try #require(remote.featureConfigurationRefreshCoordinator)
    let current = try await coordinator.current()

    #expect(local.applicationIdentifier == "com.example.odyssey.app")
    #expect(local.featureConfigurationTrust?.keyID == "synthetic-key-1")
    #expect(remote.featureConfigurationTransport != nil)
    #expect(current.source == .safeDefaultsMissing)
    #expect(current.assignments[.proactiveNotifications] == "disabled")
    #expect(throws: NativeApplicationConfigurationError.invalidRemoteEnvironment) {
        try NativeRemoteServices(
            localServices: local,
            configuration: NativeRemoteConfiguration(
                baseURL: URL(string: "https://api.example.test")!,
                environment: .production,
                platform: .iOS,
                appVersion: "1.0-test"
            )
        )
    }
}

@Test
func nativeFeatureTrustRejectsInvalidKeyMaterial() {
    #expect(throws: NativeFeatureConfigurationTrustError.invalidKeyID) {
        try NativeFeatureConfigurationTrust(
            keyID: "unsafe key",
            publicKeyBase64: compositionPublicKey.base64EncodedString(),
            environment: .staging
        )
    }
    #expect(throws: NativeFeatureConfigurationTrustError.invalidPublicKey) {
        try NativeFeatureConfigurationTrust(
            keyID: "synthetic-key-1",
            publicKeyBase64: Data(repeating: 0, count: 31).base64EncodedString(),
            environment: .staging
        )
    }
}

private actor CompositionMemoryVault: CredentialVault {
    let deviceID: UUIDv7

    init(deviceID: UUIDv7) {
        self.deviceID = deviceID
    }

    func loadOrCreateDeviceID() async throws -> UUIDv7 {
        deviceID
    }

    func refreshCredential() async throws -> StoredRefreshCredential? {
        nil
    }

    func storeRefreshCredential(_: StoredRefreshCredential) async throws {}
    func clearRefreshCredential() async throws {}
    func clearAll() async throws {}
}

private func compositionIdentifier(_ value: Int) throws -> UUIDv7 {
    try UUIDv7(validating: UUID(
        uuidString: "018f0000-0000-7000-8000-\(String(format: "%012x", value))"
    )!)
}
