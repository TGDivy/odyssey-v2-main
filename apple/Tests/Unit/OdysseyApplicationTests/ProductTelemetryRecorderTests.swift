import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseyIntelligence
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
func productTelemetryRecorderCapturesPayloadFreeAbandonmentStage() async throws {
    let fixture = try ProductTelemetryRecorderFixture()
    defer { fixture.remove() }
    try fixture.enable(questions: [.captureFriction])
    let recorder = try fixture.recorder()

    await recorder.recordCaptureAbandonment(
        kind: .fileReference,
        invokingSurface: .iPhoneGlobalCapture,
        exitStage: .selection,
        startedAt: productTelemetryRecorderDate.addingTimeInterval(-4),
        finishedAt: productTelemetryRecorderDate
    )

    let events = try fixture.events(from: productTelemetryRecorderDate.addingTimeInterval(-5))
    #expect(events.map(\.eventName) == [
        .captureWorkflowStarted,
        .captureWorkflowFinished,
    ])
    #expect(events[1].properties == [
        "capture_kind": .string("file_reference"),
        "invoking_surface": .string("iphone_global_capture"),
        "outcome": .string("abandoned"),
        "exit_stage": .string("selection"),
        "duration_bucket": .string("3_to_5s"),
    ])
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

@Test
func productTelemetryRecorderCapturesBoundedTomorrowMapLifecycle() async throws {
    let fixture = try ProductTelemetryRecorderFixture()
    defer { fixture.remove() }
    try fixture.enable(questions: [.tomorrowMapValue])
    let recorder = try fixture.recorder()
    let projection = try TomorrowMapProjector().project(TomorrowMapInput(
        generatedAt: productTelemetryRecorderDate.addingTimeInterval(-10),
        localDay: try LocalDate(
            containing: productTelemetryRecorderDate.addingTimeInterval(86_400),
            in: "UTC"
        ),
        timeZoneID: "UTC",
        calendarState: .fresh,
        commitments: []
    ))

    #expect(await recorder.recordTomorrowMapAvailability(projection) == .recorded)
    let session = try #require(await recorder.beginTomorrowMapSession(
        calendarState: projection.calendarState,
        entryPoint: .automaticNow,
        at: productTelemetryRecorderDate.addingTimeInterval(-5)
    ))
    #expect(await recorder.recordTomorrowMapFeedback(
        rating: .notUseful,
        reason: .wrongContext,
        session: session
    ) == .recorded)
    #expect(await recorder.finishTomorrowMapSession(
        session,
        outcome: .feedback
    ) == .recorded)
    #expect(await recorder.recordTomorrowMapPlanDeviation(
        deviation: .material,
        influence: .helped
    ) == .recorded)

    let events = try fixture.events(from: productTelemetryRecorderDate.addingTimeInterval(-20))
    #expect(events.count == 5)
    let availability = try #require(events.first {
        $0.eventName == .tomorrowMapAvailabilityEvaluated
    })
    #expect(availability.properties == [
        "calendar_state": .string("fresh"),
        "intentionally_absent": .boolean(true),
        "transition_count": .integer(0),
        "pressure_present": .boolean(false),
        "protected_open_present": .boolean(true),
    ])
    let viewed = try #require(events.first { $0.eventName == .tomorrowMapViewed })
    let feedback = try #require(events.first {
        $0.eventName == .tomorrowMapFeedbackRecorded
    })
    let finished = try #require(events.first {
        $0.eventName == .tomorrowMapSessionFinished
    })
    let deviation = try #require(events.first {
        $0.eventName == .tomorrowMapPlanDeviationRecorded
    })
    #expect(viewed.properties["entry_point"] == .string("automatic_now"))
    #expect(feedback.properties == [
        "rating": .string("not_useful"),
        "reason": .string("wrong_context"),
    ])
    #expect(finished.properties == [
        "duration_bucket": .string("5_to_10s"),
        "outcome": .string("feedback"),
    ])
    #expect(deviation.properties == [
        "deviation": .string("material"),
        "map_influence": .string("helped"),
    ])
    #expect(feedback.sessionID == viewed.sessionID)
    #expect(finished.sessionID == viewed.sessionID)
    #expect(feedback.causalParentEventID == viewed.eventID)
    #expect(finished.causalParentEventID == viewed.eventID)
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

    func events(
        from: Date = productTelemetryRecorderDate.addingTimeInterval(-1)
    ) throws -> [ProductTelemetryEvent] {
        try store.productTelemetryEvents(
            from: from,
            to: productTelemetryRecorderDate.addingTimeInterval(1),
            limit: 20
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
