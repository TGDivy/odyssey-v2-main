import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let telemetryPrivacyDate = Date(timeIntervalSince1970: 1_786_838_400)
private let telemetryPrivacyDeviceID = try! UUIDv7(
    validating: UUID(uuidString: "018f0000-0000-7000-8000-000000000091")!
)

@Test
func productTelemetryPrivacyDefaultsOffAndReportsEffectiveSafeFlags() async throws {
    let fixture = try ProductTelemetryPrivacyFixture()
    defer { fixture.remove() }

    let snapshot = try await fixture.service.snapshot()

    #expect(snapshot.summary.preferences == .disabled)
    #expect(snapshot.summary.retainedEventCount == 0)
    #expect(snapshot.featureConfiguration?.source == .safeDefaultsUnconfigured)
    #expect(snapshot.featureConfiguration?.assignments[.captureTelemetryQuestion] == "enabled")
    #expect(snapshot.featureConfiguration?.assignments[.proactiveNotifications] == "disabled")
    #expect(snapshot.recorderDiagnostics.recordedEventCount == 0)
}

@Test
func productTelemetryPrivacyAppliesRetentionAndExplicitDeletionLocally() async throws {
    let fixture = try ProductTelemetryPrivacyFixture()
    defer { fixture.remove() }
    try await fixture.service.updatePreferences(fixture.preferences(retentionDays: 7))
    #expect(try fixture.store.appendProductTelemetryEvent(fixture.captureStartedEvent(
        occurredAt: telemetryPrivacyDate.addingTimeInterval(-2 * 86_400),
        identifier: 92
    )))
    #expect(try await fixture.service.snapshot().summary.retainedEventCount == 1)

    try await fixture.service.updatePreferences(fixture.preferences(retentionDays: 1))
    #expect(try await fixture.service.snapshot().summary.retainedEventCount == 0)

    try await fixture.service.updatePreferences(fixture.preferences(retentionDays: 7))
    #expect(try fixture.store.appendProductTelemetryEvent(fixture.captureStartedEvent(
        occurredAt: telemetryPrivacyDate.addingTimeInterval(-60),
        identifier: 93
    )))
    #expect(try await fixture.service.deleteAllEvents() == 1)
    #expect(try await fixture.service.snapshot().summary.retainedEventCount == 0)
    #expect(try await fixture.service.snapshot().summary.preferences.collectionMode == .localOnly)
}

@Test
func productTelemetryPrivacyKeepsControlsAvailableWithoutFeatureDiagnostics() async throws {
    let fixture = try ProductTelemetryPrivacyFixture()
    defer { fixture.remove() }
    let service = ProductTelemetryPrivacyService(
        store: fixture.store,
        recorder: fixture.recorder,
        featureConfiguration: { throw ProductTelemetryPrivacyFixtureError.unavailable },
        clock: { telemetryPrivacyDate }
    )

    let snapshot = try await service.snapshot()
    #expect(snapshot.summary.preferences == .disabled)
    #expect(snapshot.featureConfiguration == nil)
}

private enum ProductTelemetryPrivacyFixtureError: Error {
    case unavailable
}

private struct ProductTelemetryPrivacyFixture {
    let directory: URL
    let store: SQLiteLedgerStore
    let recorder: ProductTelemetryRecorder
    let service: ProductTelemetryPrivacyService

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-product-telemetry-privacy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuredStore = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: telemetryPrivacyDeviceID,
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { telemetryPrivacyDate }
        ))
        store = configuredStore
        let configuredRecorder = try ProductTelemetryRecorder(
            store: configuredStore,
            deviceID: telemetryPrivacyDeviceID,
            appBuild: "1.0.0 (91)",
            featureAssignments: { FeatureFlagRegistry.safeDefaults },
            clock: { telemetryPrivacyDate }
        )
        recorder = configuredRecorder
        service = ProductTelemetryPrivacyService(
            store: configuredStore,
            recorder: configuredRecorder,
            featureConfiguration: {
                try configuredStore.resolveFeatureConfiguration(
                    assignmentSubject: telemetryPrivacyDeviceID.description
                )
            },
            clock: { telemetryPrivacyDate }
        )
    }

    func preferences(retentionDays: Int) throws -> ProductTelemetryPreferences {
        try ProductTelemetryPreferences(
            collectionMode: .localOnly,
            enabledQuestions: ProductTelemetryQuestionID.allCases,
            retentionDays: retentionDays
        )
    }

    func captureStartedEvent(
        occurredAt: Date,
        identifier: Int
    ) throws -> ProductTelemetryEvent {
        let eventID = try UUIDv7(validating: #require(UUID(uuidString: String(
            format: "018f0000-0000-7000-8000-%012llx",
            Int64(identifier)
        ))))
        return try ProductTelemetryEvent(
            eventID: eventID,
            occurredAt: occurredAt,
            receivedAt: occurredAt,
            deviceID: telemetryPrivacyDeviceID,
            appBuild: "1.0.0 (91)",
            surface: "iphone_now",
            eventName: .captureWorkflowStarted,
            contextVersion: "product_telemetry_registry_v1",
            properties: [
                "capture_kind": .string("text"),
                "invoking_surface": .string("iphone_now"),
            ]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
