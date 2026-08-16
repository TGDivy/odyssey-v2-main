import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let productTelemetryRecorderDate = Date(timeIntervalSince1970: 1_786_838_400)
private let productTelemetryRecorderDeviceID = try! UUIDv7(
    validating: UUID(uuidString: "018f0000-0000-7000-8000-000000000071")!
)

@Test
func productTelemetryRecorderCapturesLifecycleWithoutCapturePayload() async throws {
    let fixture = try ProductTelemetryRecorderFixture()
    defer { fixture.remove() }
    try fixture.enable()
    let recorder = try fixture.recorder()
    let captureService = try ManualCaptureService(
        store: fixture.store,
        deviceID: productTelemetryRecorderDeviceID,
        productTelemetryRecorder: recorder,
        clock: { productTelemetryRecorderDate }
    )
    let privatePayload = "private capture payload that must not enter product telemetry"

    _ = try await captureService.record(.text(
        privatePayload,
        timeZoneID: "UTC",
        locationPermissionState: .unavailable,
        invokingSurface: .iPhoneNow
    ))

    let events = try fixture.events()
    #expect(events.map(\.eventName) == [
        .captureWorkflowStarted,
        .captureWorkflowFinished,
    ])
    #expect(events.allSatisfy(\.localOnly))
    #expect(events[0].properties == [
        "capture_kind": .string("text"),
        "invoking_surface": .string("iphone_now"),
    ])
    #expect(events[1].properties == [
        "capture_kind": .string("text"),
        "invoking_surface": .string("iphone_now"),
        "outcome": .string("committed"),
        "exit_stage": .string("local_commit"),
        "duration_bucket": .string("under_1s"),
    ])
    #expect(events[0].sessionID == events[1].sessionID)
    #expect(events[1].causalParentEventID == events[0].eventID)
    #expect(events.allSatisfy {
        $0.featureFlagAssignments[FeatureFlagKey.captureTelemetryQuestion.rawValue]
            == "enabled"
    })

    let encodedEvents = try events.map { event in
        try ProductTelemetryCoding.makeEncoder().encode(event)
    }
    let telemetryText = encodedEvents.compactMap { String(data: $0, encoding: .utf8) }
        .joined(separator: "\n")
    #expect(!telemetryText.contains(privatePayload))
    #expect(!telemetryText.contains("content_or_object_ref"))

    let diagnostics = await recorder.diagnostics()
    #expect(diagnostics.attemptedEventCount == 2)
    #expect(diagnostics.recordedEventCount == 2)
    #expect(diagnostics.failedEventCount == 0)
}

@Test
func productTelemetryRecorderRequiresOwnerQuestionAndFeatureConsent() async throws {
    let fixture = try ProductTelemetryRecorderFixture()
    defer { fixture.remove() }
    let enabledRecorder = try fixture.recorder()

    #expect(await enabledRecorder.beginCaptureWorkflow(
        kind: .text,
        invokingSurface: .iPhoneNow
    ) == nil)
    var diagnostics = await enabledRecorder.diagnostics()
    #expect(diagnostics.preferenceSkippedEventCount == 1)

    try fixture.enable(questions: [.tomorrowMapValue])
    #expect(await enabledRecorder.beginCaptureWorkflow(
        kind: .text,
        invokingSurface: .iPhoneNow
    ) == nil)
    diagnostics = await enabledRecorder.diagnostics()
    #expect(diagnostics.preferenceSkippedEventCount == 2)

    try fixture.enable(questions: [.captureFriction])
    let disabledFlagRecorder = try fixture.recorder(assignments: [
        .captureTelemetryQuestion: "disabled",
        .tomorrowMapTelemetryQuestion: "enabled",
        .weeklyProductReview: "enabled",
        .proactiveNotifications: "disabled",
    ])
    #expect(await disabledFlagRecorder.beginCaptureWorkflow(
        kind: .text,
        invokingSurface: .iPhoneNow
    ) == nil)
    diagnostics = await disabledFlagRecorder.diagnostics()
    #expect(diagnostics.featureFlagSkippedEventCount == 1)
    #expect(try fixture.events().isEmpty)
}

@Test
func productTelemetryFailureNeverBlocksDurableCapture() async throws {
    let fixture = try ProductTelemetryRecorderFixture()
    defer { fixture.remove() }
    try fixture.enable()
    let recorder = try ProductTelemetryRecorder(
        store: fixture.store,
        deviceID: productTelemetryRecorderDeviceID,
        appBuild: "1.0.0 (71)",
        featureAssignments: { throw ProductTelemetryRecorderFixtureError.unavailable },
        clock: { productTelemetryRecorderDate }
    )
    let captureService = try ManualCaptureService(
        store: fixture.store,
        deviceID: productTelemetryRecorderDeviceID,
        productTelemetryRecorder: recorder,
        clock: { productTelemetryRecorderDate }
    )

    let receipt = try await captureService.record(.text(
        "capture still commits",
        timeZoneID: "UTC",
        locationPermissionState: .unavailable,
        invokingSurface: .iPhoneNow
    ))

    #expect(try fixture.store.projectedEntity(
        entityType: ManualCaptureService.entityType,
        entityID: receipt.capture.metadata.id
    ) != nil)
    #expect(try fixture.events().isEmpty)
    let diagnostics = await recorder.diagnostics()
    #expect(diagnostics.failedEventCount == 1)
    #expect(diagnostics.lastFailure == .featureConfiguration)
}

private enum ProductTelemetryRecorderFixtureError: Error {
    case unavailable
}

private struct ProductTelemetryRecorderFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-product-telemetry-recorder-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: productTelemetryRecorderDeviceID,
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { productTelemetryRecorderDate }
        ))
    }

    func enable(
        questions: [ProductTelemetryQuestionID] = ProductTelemetryQuestionID.allCases
    ) throws {
        try store.putProductTelemetryPreferences(
            ProductTelemetryPreferences(
                collectionMode: .localOnly,
                enabledQuestions: questions,
                retentionDays: 7
            ),
            updatedAt: productTelemetryRecorderDate
        )
    }

    func recorder(
        assignments: [FeatureFlagKey: String] = FeatureFlagRegistry.safeDefaults
    ) throws -> ProductTelemetryRecorder {
        try ProductTelemetryRecorder(
            store: store,
            deviceID: productTelemetryRecorderDeviceID,
            appBuild: "1.0.0 (71)",
            featureAssignments: { assignments },
            clock: { productTelemetryRecorderDate }
        )
    }

    func events() throws -> [ProductTelemetryEvent] {
        try store.productTelemetryEvents(
            from: productTelemetryRecorderDate.addingTimeInterval(-1),
            to: productTelemetryRecorderDate.addingTimeInterval(1),
            limit: 20
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
