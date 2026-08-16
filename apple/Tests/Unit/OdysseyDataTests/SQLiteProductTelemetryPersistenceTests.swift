import Foundation
@testable import OdysseyData
import OdysseyDomain
import OdysseyTelemetry
import Testing

private let telemetryPersistenceDate = Date(timeIntervalSince1970: 1_786_838_400)
private let telemetryDeviceID = try! UUIDv7(
    validating: UUID(uuidString: "018f0000-0000-7000-8000-000000000001")!
)

@Test
func productTelemetryDefaultsOffThenPersistsEnabledEventsIdempotently() throws {
    let fixture = try ProductTelemetryPersistenceFixture()
    defer { fixture.remove() }
    let event = try fixture.event()

    #expect(try fixture.store.productTelemetryPreferences() == .disabled)
    #expect(!(try fixture.store.appendProductTelemetryEvent(event)))

    try fixture.enable(retentionDays: 7)
    #expect(try fixture.store.appendProductTelemetryEvent(event))
    #expect(!(try fixture.store.appendProductTelemetryEvent(event)))
    #expect(try fixture.store.productTelemetryEvents(
        from: telemetryPersistenceDate.addingTimeInterval(-1),
        to: telemetryPersistenceDate.addingTimeInterval(1),
        limit: 10
    ) == [event])

    let summary = try fixture.store.productTelemetrySummary(at: telemetryPersistenceDate)
    #expect(summary.retainedEventCount == 1)
    #expect(summary.oldestEventAt == telemetryPersistenceDate)
    #expect(summary.nextExpiryAt == telemetryPersistenceDate.addingTimeInterval(7 * 86_400))
    #expect(try fixture.store.integrityReport().schemaVersion == 6)
}

@Test
func productTelemetryStorageEnforcesQuestionDeviceAndLocalOnlyGates() throws {
    let fixture = try ProductTelemetryPersistenceFixture()
    defer { fixture.remove() }
    try fixture.enable(questions: [.captureFriction])

    #expect(!(try fixture.store.appendProductTelemetryEvent(fixture.event())))
    #expect(throws: ProductTelemetryPersistenceError.deviceMismatch) {
        try fixture.store.appendProductTelemetryEvent(fixture.event(
            deviceID: try fixture.uuid7("018f0000-0000-7000-8000-000000000099")
        ))
    }
    #expect(throws: ProductTelemetryPersistenceError.uploadNotSupported) {
        try fixture.store.appendProductTelemetryEvent(fixture.event(localOnly: false))
    }
}

@Test
func productTelemetryRejectsConflictingIdentityAndPrunesByOwnerRetention() throws {
    let fixture = try ProductTelemetryPersistenceFixture()
    defer { fixture.remove() }
    try fixture.enable(retentionDays: 30)
    let eventID = try fixture.uuid7("018f0000-0000-7000-8000-000000000010")
    #expect(try fixture.store.appendProductTelemetryEvent(fixture.event(eventID: eventID)))
    #expect(throws: ProductTelemetryPersistenceError.conflictingEvent) {
        try fixture.store.appendProductTelemetryEvent(fixture.event(
            eventID: eventID,
            transitionCount: 1
        ))
    }

    try fixture.enable(
        retentionDays: 1,
        updatedAt: telemetryPersistenceDate.addingTimeInterval(2 * 86_400)
    )
    #expect(try fixture.store.productTelemetrySummary(
        at: telemetryPersistenceDate.addingTimeInterval(2 * 86_400)
    ).retainedEventCount == 0)
}

@Test
func productTelemetrySupportsExplicitLocalDeletion() throws {
    let fixture = try ProductTelemetryPersistenceFixture()
    defer { fixture.remove() }
    try fixture.enable()
    #expect(try fixture.store.appendProductTelemetryEvent(fixture.event()))
    #expect(try fixture.store.deleteAllProductTelemetry() == 1)
    #expect(try fixture.store.deleteAllProductTelemetry() == 0)
    #expect(try fixture.store.productTelemetrySummary(
        at: telemetryPersistenceDate
    ).retainedEventCount == 0)
}

@Test
func productTelemetryDetectsDocumentTampering() async throws {
    let fixture = try ProductTelemetryPersistenceFixture()
    defer { fixture.remove() }
    try fixture.enable()
    #expect(try fixture.store.appendProductTelemetryEvent(fixture.event()))
    try await fixture.store.databasePool.write { database in
        let session = SQLiteSession(database: database)
        try session.execute("DROP TRIGGER product_telemetry_events_no_update")
        try session.execute("UPDATE product_telemetry_events SET document = X'00'")
    }

    #expect(throws: SQLiteLedgerError.self) {
        try fixture.store.productTelemetryEvents(
            from: telemetryPersistenceDate.addingTimeInterval(-1),
            to: telemetryPersistenceDate.addingTimeInterval(1),
            limit: 10
        )
    }
    #expect(throws: SQLiteLedgerError.self) {
        try fixture.store.integrityReport()
    }
}

private struct ProductTelemetryPersistenceFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-product-telemetry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: telemetryDeviceID,
            preMigrationBackupDirectory: directory,
            clock: { telemetryPersistenceDate }
        ))
    }

    func enable(
        questions: [ProductTelemetryQuestionID] = ProductTelemetryQuestionID.allCases,
        retentionDays: Int = 7,
        updatedAt: Date = telemetryPersistenceDate
    ) throws {
        try store.putProductTelemetryPreferences(
            ProductTelemetryPreferences(
                collectionMode: .localOnly,
                enabledQuestions: questions,
                retentionDays: retentionDays
            ),
            updatedAt: updatedAt
        )
    }

    func event(
        eventID: UUIDv7? = nil,
        deviceID: UUIDv7 = telemetryDeviceID,
        transitionCount: Int = 2,
        localOnly: Bool = true
    ) throws -> ProductTelemetryEvent {
        try ProductTelemetryEvent(
            eventID: eventID ?? uuid7("018f0000-0000-7000-8000-000000000010"),
            occurredAt: telemetryPersistenceDate,
            receivedAt: telemetryPersistenceDate,
            deviceID: deviceID,
            appBuild: "1.0.0+1",
            surface: "iphone_now",
            eventName: .tomorrowMapAvailabilityEvaluated,
            contextVersion: "native-now-context-1",
            properties: [
                "calendar_state": .string("fresh"),
                "intentionally_absent": .boolean(false),
                "transition_count": .integer(transitionCount),
                "pressure_present": .boolean(true),
                "protected_open_present": .boolean(false),
            ],
            localOnly: localOnly
        )
    }

    func uuid7(_ value: String) throws -> UUIDv7 {
        try UUIDv7(validating: #require(UUID(uuidString: value)))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
