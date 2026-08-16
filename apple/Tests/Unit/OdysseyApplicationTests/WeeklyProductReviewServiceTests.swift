import Foundation
import OdysseyApplication
import OdysseyData
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let weeklyProductReviewServiceDate = Date(timeIntervalSince1970: 1_786_838_400)
private let weeklyProductReviewServiceDeviceID = try! UUIDv7(
    validating: UUID(uuidString: "018f0000-0000-7000-8000-000000000081")!
)

@Test
func weeklyProductReviewServiceReadsTheBoundedLocalWindow() throws {
    let fixture = try WeeklyProductReviewServiceFixture()
    defer { fixture.remove() }
    try fixture.enable()
    #expect(try fixture.store.appendProductTelemetryEvent(fixture.captureStartedEvent()))
    let service = fixture.service()

    let availability = try service.generate()
    guard case let .available(artifact) = availability else {
        Issue.record("Expected the weekly review feature to be enabled.")
        return
    }
    #expect(artifact.sourceQuality.retainedEventCount == 1)
    #expect(artifact.capture.workflowStartedCount == 1)
    #expect(artifact.capture.openWorkflowCount == 1)
    #expect(artifact.preferences.collectionMode == .localOnly)
}

@Test
func weeklyProductReviewServiceHonorsItsFeatureGate() throws {
    let fixture = try WeeklyProductReviewServiceFixture()
    defer { fixture.remove() }
    let assignments: [FeatureFlagKey: String] = [
        .captureTelemetryQuestion: "enabled",
        .tomorrowMapTelemetryQuestion: "enabled",
        .weeklyProductReview: "disabled",
        .proactiveNotifications: "disabled",
    ]

    #expect(try fixture.service(assignments: assignments).generate()
        == .disabledByFeatureFlag)
}

@Test
func weeklyProductReviewServiceUsesStableFailureCategories() throws {
    let fixture = try WeeklyProductReviewServiceFixture()
    defer { fixture.remove() }
    let unavailable = WeeklyProductReviewService(
        store: fixture.store,
        featureAssignments: { throw WeeklyProductReviewServiceFixtureError.unavailable },
        clock: { weeklyProductReviewServiceDate }
    )
    let invalidClock = WeeklyProductReviewService(
        store: fixture.store,
        featureAssignments: { FeatureFlagRegistry.safeDefaults },
        clock: { Date(timeIntervalSinceReferenceDate: .nan) }
    )

    #expect(throws: WeeklyProductReviewServiceError.featureConfigurationUnavailable) {
        try unavailable.generate()
    }
    #expect(throws: WeeklyProductReviewServiceError.invalidClock) {
        try invalidClock.generate()
    }
}

private enum WeeklyProductReviewServiceFixtureError: Error {
    case unavailable
}

private struct WeeklyProductReviewServiceFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-weekly-product-review-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: weeklyProductReviewServiceDeviceID,
            preMigrationBackupDirectory: directory.appendingPathComponent("backups"),
            clock: { weeklyProductReviewServiceDate }
        ))
    }

    func enable() throws {
        try store.putProductTelemetryPreferences(
            ProductTelemetryPreferences(
                collectionMode: .localOnly,
                enabledQuestions: ProductTelemetryQuestionID.allCases,
                retentionDays: 7
            ),
            updatedAt: weeklyProductReviewServiceDate
        )
    }

    func service(
        assignments: [FeatureFlagKey: String] = FeatureFlagRegistry.safeDefaults
    ) -> WeeklyProductReviewService {
        WeeklyProductReviewService(
            store: store,
            featureAssignments: { assignments },
            clock: { weeklyProductReviewServiceDate }
        )
    }

    func captureStartedEvent() throws -> ProductTelemetryEvent {
        let occurredAt = weeklyProductReviewServiceDate.addingTimeInterval(-60)
        return try ProductTelemetryEvent(
            occurredAt: occurredAt,
            receivedAt: occurredAt,
            sessionID: try UUIDv7(
                validating: #require(
                    UUID(uuidString: "018f0000-0000-7000-8000-000000000082")
                )
            ),
            deviceID: weeklyProductReviewServiceDeviceID,
            appBuild: "1.0.0 (81)",
            surface: "iphone_now",
            eventName: .captureWorkflowStarted,
            contextVersion: "product_telemetry_registry_v1",
            featureFlagAssignments: [
                FeatureFlagKey.captureTelemetryQuestion.rawValue: "enabled",
            ],
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
