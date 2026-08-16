import Foundation
@testable import OdysseyData
import OdysseyDomain
import OdysseyIntegrations
import Testing

private let integrationPersistenceDate = Date(timeIntervalSince1970: 1_786_838_400)

@Test
func sqliteIntegrationMirrorPersistsAtomicPagesAndImmutableConflictPolicy() async throws {
    let fixture = try IntegrationPersistenceFixture()
    defer { fixture.remove() }
    let first = try fixture.record(document: Data("first".utf8))
    let initialPage = try IntegrationLocalPage(
        connector: .health,
        stream: "heart_rate",
        records: [first],
        deletedExternalIdentifiers: [],
        nextCursor: Data([1]),
        appliedAt: integrationPersistenceDate,
        allowsUpdates: false
    )

    let inserted = try await fixture.store.applyIntegrationPage(initialPage)
    let duplicate = try await fixture.store.applyIntegrationPage(initialPage)
    let conflict = try await fixture.store.applyIntegrationPage(IntegrationLocalPage(
        connector: .health,
        stream: "heart_rate",
        records: [fixture.record(document: Data("changed".utf8))],
        deletedExternalIdentifiers: [],
        nextCursor: Data([2]),
        appliedAt: integrationPersistenceDate,
        allowsUpdates: false
    ))
    let snapshot = try await fixture.store.integrationSnapshot(
        connector: .health,
        stream: "heart_rate"
    )

    #expect(inserted.insertedCount == 1)
    #expect(duplicate.duplicateCount == 1)
    #expect(conflict.rejectedCount == 1)
    #expect(snapshot.records == [first])
    #expect(snapshot.cursor == Data([2]))

    let deleted = try await fixture.store.applyIntegrationPage(IntegrationLocalPage(
        connector: .health,
        stream: "heart_rate",
        records: [],
        deletedExternalIdentifiers: [first.externalIdentifier],
        nextCursor: Data([3]),
        appliedAt: integrationPersistenceDate,
        allowsUpdates: false
    ))
    #expect(deleted.deletedCount == 1)
    #expect(try await fixture.store.integrationSnapshot(
        connector: .health,
        stream: "heart_rate"
    ).records.isEmpty)
}

@Test
func sqliteIntegrationMirrorUpdatesMutableRecordsAndClearsConnectorData() async throws {
    let fixture = try IntegrationPersistenceFixture()
    defer { fixture.remove() }
    let first = try fixture.record(
        connector: .calendar,
        stream: "events",
        document: Data("first".utf8)
    )
    let changed = try fixture.record(
        connector: .calendar,
        stream: "events",
        document: Data("changed".utf8)
    )
    _ = try await fixture.store.applyIntegrationPage(IntegrationLocalPage(
        connector: .calendar,
        stream: "events",
        records: [first],
        deletedExternalIdentifiers: [],
        nextCursor: nil,
        appliedAt: integrationPersistenceDate,
        allowsUpdates: true
    ))
    let updated = try await fixture.store.applyIntegrationPage(IntegrationLocalPage(
        connector: .calendar,
        stream: "events",
        records: [changed],
        deletedExternalIdentifiers: [],
        nextCursor: nil,
        appliedAt: integrationPersistenceDate,
        allowsUpdates: true
    ))

    #expect(updated.updatedCount == 1)
    #expect(try await fixture.store.integrationSnapshot(
        connector: .calendar,
        stream: "events"
    ).records == [changed])
    #expect(try await fixture.store.clearIntegrationData(connector: .calendar) == 1)
    #expect(try await fixture.store.integrationSnapshot(
        connector: .calendar,
        stream: "events"
    ).records.isEmpty)
}

@Test
func sqliteIntegrationMirrorRejectsTamperedDocumentsBeforeRead() async throws {
    let fixture = try IntegrationPersistenceFixture()
    defer { fixture.remove() }
    _ = try await fixture.store.applyIntegrationPage(IntegrationLocalPage(
        connector: .health,
        stream: "heart_rate",
        records: [fixture.record(document: Data("trusted".utf8))],
        deletedExternalIdentifiers: [],
        nextCursor: Data([1]),
        appliedAt: integrationPersistenceDate,
        allowsUpdates: false
    ))
    try await fixture.store.databasePool.write { database in
        try SQLiteSession(database: database).execute(
            "UPDATE integration_records SET document = X'00'"
        )
    }

    await #expect(throws: SQLiteLedgerError.self) {
        try await fixture.store.integrationSnapshot(
            connector: .health,
            stream: "heart_rate"
        )
    }
}

private struct IntegrationPersistenceFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-integration-persistence-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("ledger.sqlite"),
            deviceID: try UUIDv7(
                validating: UUID(uuidString: "018f0000-0000-7000-8000-000000000001")!
            ),
            preMigrationBackupDirectory: directory,
            clock: { integrationPersistenceDate }
        ))
    }

    func record(
        connector: IntegrationConnector = .health,
        stream: String = "heart_rate",
        document: Data
    ) throws -> IntegrationLocalRecord {
        try IntegrationLocalRecord(
            connector: connector,
            stream: stream,
            externalIdentifier: "00000000-0000-4000-8000-000000000001",
            sourceTimestamp: integrationPersistenceDate,
            document: document
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
