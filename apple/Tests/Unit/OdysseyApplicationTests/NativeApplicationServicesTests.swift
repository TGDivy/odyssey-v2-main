import Foundation
import OdysseyApplication
import OdysseyAuth
import OdysseyDomain
import Testing

@Test
func localServicesUseStableCredentialIdentityAndApplicationSupportLayout() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-native-services-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let deviceID = try servicesIdentifier(1)
    let vault = ServicesMemoryVault(deviceID: deviceID)
    let configuration = try NativeLocalConfiguration(
        applicationIdentifier: "com.example.odyssey.app",
        applicationSupportDirectory: directory
    )

    let services = try await NativeLocalServices.bootstrap(
        configuration: configuration,
        vault: vault
    )
    let receipt = try await services.captureService.record(
        .text(
            "available before remote configuration",
            timeZoneID: "UTC",
            locationPermissionState: .unavailable,
            invokingSurface: .iPhoneNow
        )
    )
    _ = try await services.captureInterpretationService.interpret(
        captureID: receipt.capture.metadata.id,
        using: DeterministicCaptureInterpreter()
    )

    #expect(services.deviceID == deviceID)
    #expect(configuration.databaseURL.lastPathComponent == "odyssey.sqlite")
    #expect(configuration.databaseURL.path.contains("/Data/"))
    #expect(configuration.preMigrationBackupDirectory.path.hasSuffix("/Backups/Migrations"))
    #expect(configuration.attachmentDirectory.path.hasSuffix("/Attachments/v1"))
    #expect(
        configuration.captureImportDirectory.path
            .hasSuffix("/CaptureImports/Temporary/v1")
    )
    #expect(FileManager.default.fileExists(atPath: configuration.databaseURL.path))
    #expect(receipt.deviceSequence == 1)
    let diagnostics = try await services.localDiagnostics()
    let workshop = try await services.lifeModelWorkshopService.snapshot()
    let foodPresets = try await services.foodPresetService.activePresets()
    #expect(diagnostics.operationsQueued == 2)
    #expect(diagnostics.deviceCursor.value == 0)
    #expect(workshop.drafts.isEmpty)
    #expect(workshop.acceptanceCommands.isEmpty)
    #expect(foodPresets.isEmpty)
    let captures = try services.recentCaptures()
    #expect(captures.count == 1)
    #expect(
        captures[0].originalPayload.contentOrObjectRef
            == "available before remote configuration"
    )
    #expect(captures[0].interpretationStatus == .interpreted)
    #expect(captures[0].interpretationVersions.count == 1)
}

@Test
func remoteConfigurationAllowsOnlyHTTPSOrDevelopmentLoopback() throws {
    let development = try NativeRemoteConfiguration(
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        environment: .development,
        platform: .iOS,
        appVersion: "1.0 (1)"
    )
    #expect(development.allowsInsecureLoopbackDevelopment)
    #expect(development.userAgent == "Odyssey/1.0 (1) (ios; development)")

    #expect(throws: NativeApplicationConfigurationError.insecureRemoteHost) {
        try NativeRemoteConfiguration(
            baseURL: URL(string: "http://api.example.com")!,
            environment: .production,
            platform: .iOS,
            appVersion: "1.0"
        )
    }
    #expect(throws: NativeApplicationConfigurationError.placeholderRemoteHost) {
        try NativeRemoteConfiguration(
            baseURL: URL(string: "https://api.example.invalid")!,
            environment: .production,
            platform: .iOS,
            appVersion: "1.0"
        )
    }
}

@Test
func remoteServicesComposeAuthTokenTransportAndOfflineDiagnostics() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "odyssey-remote-services-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = try await NativeLocalServices.bootstrap(
        configuration: NativeLocalConfiguration(
            applicationIdentifier: "com.example.odyssey.app",
            applicationSupportDirectory: directory
        ),
        vault: ServicesMemoryVault(deviceID: try servicesIdentifier(10))
    )
    let remote = try NativeRemoteServices(
        localServices: local,
        configuration: NativeRemoteConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            environment: .staging,
            platform: .iOS,
            appVersion: "1.0-test"
        )
    )

    let diagnostics = try await remote.syncCoordinator.localDiagnostics()
    let lifeModelDiagnostics = try local.ledgerStore.lifeModelQueueDiagnostics()
    await remote.lifeModelAcceptanceCoordinator.cancelSynchronization()

    #expect(diagnostics.deviceID == local.deviceID)
    #expect(diagnostics.operationsQueued == 0)
    #expect(diagnostics.schemaCompatibility == .unknown)
    #expect(lifeModelDiagnostics.queuedCount == 0)
}

private actor ServicesMemoryVault: CredentialVault {
    private let deviceID: UUIDv7
    private var credential: StoredRefreshCredential?

    init(deviceID: UUIDv7) {
        self.deviceID = deviceID
    }

    func loadOrCreateDeviceID() async throws -> UUIDv7 {
        deviceID
    }

    func refreshCredential() async throws -> StoredRefreshCredential? {
        credential
    }

    func storeRefreshCredential(_ credential: StoredRefreshCredential) async throws {
        guard credential.deviceID == deviceID else {
            throw CredentialVaultError.deviceMismatch
        }
        self.credential = credential
    }

    func clearRefreshCredential() async throws {
        credential = nil
    }

    func clearAll() async throws {
        credential = nil
    }
}

private func servicesIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
