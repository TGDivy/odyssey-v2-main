import Foundation
@testable import OdysseyData
import OdysseyDomain
import Testing

private let applicationStateDate = Date(timeIntervalSince1970: 1_786_847_400)

@Test
func localApplicationStatePersistsReplacesAndRemovesHashVerifiedDocuments() throws {
    let fixture = try LocalApplicationStateFixture()
    defer { fixture.remove() }
    let first = try fixture.store.putLocalApplicationState(
        key: "now_experience",
        schemaVersion: 1,
        document: Data("first".utf8),
        updatedAt: applicationStateDate
    )
    let second = try fixture.store.putLocalApplicationState(
        key: "now_experience",
        schemaVersion: 2,
        document: Data("second".utf8),
        updatedAt: applicationStateDate.addingTimeInterval(1)
    )

    #expect(first.documentSHA256 != second.documentSHA256)
    #expect(try fixture.store.localApplicationState(for: "now_experience") == second)
    #expect(try fixture.store.integrityReport().schemaVersion == SQLiteLedgerStore.currentSchemaVersion)
    #expect(try fixture.store.removeLocalApplicationState(for: "now_experience"))
    #expect(!(try fixture.store.removeLocalApplicationState(for: "now_experience")))
    #expect(try fixture.store.localApplicationState(for: "now_experience") == nil)
}

@Test
func localApplicationStateRejectsUnsafeOrUnboundedInputs() throws {
    let fixture = try LocalApplicationStateFixture()
    defer { fixture.remove() }

    #expect(throws: LocalApplicationStateError.invalidKey) {
        try fixture.store.putLocalApplicationState(
            key: "../unsafe",
            schemaVersion: 1,
            document: Data([1]),
            updatedAt: applicationStateDate
        )
    }
    #expect(throws: LocalApplicationStateError.invalidDocument) {
        try fixture.store.putLocalApplicationState(
            key: "bounded",
            schemaVersion: 1,
            document: Data(),
            updatedAt: applicationStateDate
        )
    }
    #expect(throws: LocalApplicationStateError.invalidDocument) {
        try fixture.store.putLocalApplicationState(
            key: "bounded",
            schemaVersion: 1,
            document: Data(repeating: 0, count: 65_537),
            updatedAt: applicationStateDate
        )
    }
}

@Test
func localApplicationStateDetectsTamperingOnReadAndIntegrityCheck() async throws {
    let fixture = try LocalApplicationStateFixture()
    defer { fixture.remove() }
    _ = try fixture.store.putLocalApplicationState(
        key: "now_experience",
        schemaVersion: 1,
        document: Data("trusted".utf8),
        updatedAt: applicationStateDate
    )
    try await fixture.store.databasePool.write { database in
        try SQLiteSession(database: database).execute(
            "UPDATE local_application_state SET document = X'00'"
        )
    }

    #expect(throws: SQLiteLedgerError.self) {
        try fixture.store.localApplicationState(for: "now_experience")
    }
    #expect(throws: SQLiteLedgerError.self) {
        try fixture.store.integrityReport()
    }
}

private struct LocalApplicationStateFixture {
    let directory: URL
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "odyssey-local-application-state-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = try SQLiteLedgerStore(configuration: SQLiteLedgerConfiguration(
            databaseURL: directory.appendingPathComponent("odyssey.sqlite"),
            deviceID: try UUIDv7(validating: UUID(
                uuidString: "018f3e1b-7c90-7abc-8def-000000000001"
            )!),
            preMigrationBackupDirectory: directory,
            clock: { applicationStateDate }
        ))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
