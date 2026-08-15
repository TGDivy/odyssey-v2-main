import Foundation
@testable import OdysseyData
import OdysseyDomain
import Testing

private let fixedDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func atomicCommitPersistsLedgerProjectionAndOutbox() async throws {
    let fixture = try LedgerFixture()
    let entityID = try fixture.identifier(1)
    let eventID = try fixture.identifier(2)
    let operationID = try fixture.identifier(3)
    let document = try fixture.json(["text": "A durable thought", "schema_version": 1])

    let receipt = try await fixture.store.commit(
        fixture.commit(
            entityID: entityID,
            eventID: eventID,
            operationID: operationID,
            document: document
        )
    )

    #expect(receipt.localSequence == 1)
    #expect(receipt.queuedOperation?.deviceSequence == 1)
    #expect(receipt.queuedOperation?.status == .pending)
    #expect(receipt.queuedOperation?.sourceEventID == eventID)

    let entries = try fixture.store.storedEntries(limit: 10)
    #expect(entries.count == 1)
    #expect(entries[0].entry.eventID == eventID)
    #expect(entries[0].payloadSHA256 == "79ccabff6ffa23071bfaf634bec2f2679dba9d386b8bd2a7fcd40a3f8f9242bc")

    let projection = try fixture.store.projectedEntity(
        entityType: "capture",
        entityID: entityID
    )
    #expect(projection?.revision == 1)
    #expect(projection?.document == document)
    #expect(projection?.tombstone == false)

    let operations = try await fixture.store.pendingSyncOperations(
        limit: 10,
        readyAt: fixedDate
    )
    #expect(operations.map(\.operationID) == [operationID])
    #expect(operations[0].payload == document)

    let state = try await fixture.store.syncState()
    #expect(state.deviceID == fixture.deviceID)
    #expect(state.cursor == "c_0")
    #expect(state.nextDeviceSequence == 2)

    let searchResults = try fixture.store.searchProjections(matching: "durable thought")
    #expect(searchResults.map(\.entity.entityID) == [entityID])
    #expect(searchResults[0].snippet.localizedCaseInsensitiveContains("durable"))

    let report = try fixture.store.integrityReport()
    #expect(report.ledgerEntryCount == 1)
    #expect(report.projectionEventCount == 1)
    #expect(report.projectedEntityCount == 1)
    #expect(report.syncOperationCount == 1)
}

@Test
func failedProjectionRollsBackLedgerAndDeviceSequence() async throws {
    let fixture = try LedgerFixture()
    let firstEntityID = try fixture.identifier(10)
    _ = try await fixture.store.commit(
        fixture.commit(
            entityID: firstEntityID,
            eventID: try fixture.identifier(11),
            operationID: try fixture.identifier(12),
            document: try fixture.json(["value": 1])
        )
    )

    let missingEntityID = try fixture.identifier(13)
    let invalidDocument = try fixture.json(["value": 2])
    let invalidCommit = fixture.commit(
        entityID: missingEntityID,
        eventID: try fixture.identifier(14),
        operationID: try fixture.identifier(15),
        document: invalidDocument,
        mutationType: .update,
        revision: 2,
        baseRevision: 1
    )

    do {
        _ = try await fixture.store.commit(invalidCommit)
        Issue.record("An update without an existing projection should fail.")
    } catch let error as SQLiteLedgerError {
        #expect(error == .invalidProjection("Update and delete projections require an existing entity."))
    }

    let entries = try fixture.store.storedEntries(limit: 10)
    let operations = try await fixture.store.pendingSyncOperations(
        limit: 10,
        readyAt: fixedDate
    )
    let state = try await fixture.store.syncState()
    #expect(entries.count == 1)
    #expect(operations.count == 1)
    #expect(state.nextDeviceSequence == 2)
}

@Test
func projectionRebuildPreservesLatestTombstone() async throws {
    let fixture = try LedgerFixture()
    let entityID = try fixture.identifier(20)
    let tombstoneDocument = try fixture.json([:])
    _ = try await fixture.store.commit(
        fixture.commit(
            entityID: entityID,
            eventID: try fixture.identifier(21),
            operationID: try fixture.identifier(22),
            document: try fixture.json(["value": 1])
        )
    )
    _ = try await fixture.store.commit(
        fixture.commit(
            entityID: entityID,
            eventID: try fixture.identifier(23),
            operationID: try fixture.identifier(24),
            document: try fixture.json(["value": 2]),
            mutationType: .update,
            revision: 2,
            baseRevision: 1
        )
    )
    _ = try await fixture.store.commit(
        fixture.commit(
            entityID: entityID,
            eventID: try fixture.identifier(25),
            operationID: try fixture.identifier(26),
            document: tombstoneDocument,
            mutationType: .delete,
            revision: 3,
            baseRevision: 2
        )
    )

    try await fixture.store.rebuildAll()
    let projection = try fixture.store.projectedEntity(
        entityType: "capture",
        entityID: entityID
    )
    #expect(projection?.revision == 3)
    #expect(projection?.tombstone == true)
    #expect(projection?.document == tombstoneDocument)
    try await fixture.store.verifyIntegrity()
}

@Test
func retryAndAcceptanceRetainDurableOperationHistory() async throws {
    let fixture = try LedgerFixture()
    let operationID = try fixture.identifier(32)
    _ = try await fixture.store.commit(
        fixture.commit(
            entityID: try fixture.identifier(30),
            eventID: try fixture.identifier(31),
            operationID: operationID,
            document: try fixture.json(["value": "offline"])
        )
    )

    let retryAt = fixedDate.addingTimeInterval(60)
    try fixture.store.markOperationForRetry(
        operationID: operationID,
        error: "synthetic network outage",
        nextAttemptAt: retryAt
    )
    let tooEarly = try await fixture.store.pendingSyncOperations(
        limit: 10,
        readyAt: fixedDate
    )
    let ready = try await fixture.store.pendingSyncOperations(
        limit: 10,
        readyAt: retryAt
    )
    #expect(tooEarly.isEmpty)
    #expect(ready.count == 1)
    #expect(ready[0].attemptCount == 1)
    #expect(ready[0].lastError == "synthetic network outage")

    try fixture.store.markOperationAccepted(
        operationID: operationID,
        canonicalRevision: 1,
        serverChangeID: 9,
        acceptedAt: retryAt
    )
    let pending = try await fixture.store.pendingSyncOperations(
        limit: 10,
        readyAt: retryAt
    )
    #expect(pending.isEmpty)

    let exportURL = fixture.directory.appendingPathComponent("history.json")
    _ = try await fixture.store.exportAll(to: exportURL)
    let archive = try fixture.decodeExport(at: exportURL)
    #expect(archive.syncOperations.count == 1)
    #expect(archive.syncOperations[0].operation.status == .accepted)
    #expect(archive.syncOperations[0].canonicalRevision == 1)
    #expect(archive.syncOperations[0].serverChangeID == 9)
}

@Test
func projectionObservationEmitsInitialAndCommittedState() async throws {
    let fixture = try LedgerFixture()
    let entityID = try fixture.identifier(35)
    let stream = fixture.store.observeProjections(entityType: "capture")
    var iterator = stream.makeAsyncIterator()

    let initial = try await iterator.next()
    #expect(initial?.isEmpty == true)

    _ = try await fixture.store.commit(
        fixture.commit(
            entityID: entityID,
            eventID: try fixture.identifier(36),
            operationID: try fixture.identifier(37),
            document: try fixture.json(["text": "observed change"])
        )
    )
    var changed: [ProjectedEntity]?
    for _ in 0 ..< 3 {
        let candidate = try await iterator.next()
        if candidate?.isEmpty == false {
            changed = candidate
            break
        }
    }
    #expect(changed?.map(\.entityID) == [entityID])
}

@Test
func onlineBackupAndOwnerExportAreReadable() async throws {
    let fixture = try LedgerFixture()
    _ = try await fixture.store.commit(
        fixture.commit(
            entityID: try fixture.identifier(40),
            eventID: try fixture.identifier(41),
            operationID: try fixture.identifier(42),
            document: try fixture.json(["text": "survives reinstall"])
        )
    )

    let backupURL = fixture.directory.appendingPathComponent("ledger-backup.sqlite3")
    let exportURL = fixture.directory.appendingPathComponent("owner-export.json")
    #expect(try await fixture.store.createBackup(at: backupURL) == backupURL)
    #expect(try await fixture.store.exportAll(to: exportURL) == exportURL)

    let attributes = try FileManager.default.attributesOfItem(atPath: backupURL.path)
    #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0)
    let archive = try fixture.decodeExport(at: exportURL)
    #expect(archive.exportFormatVersion == 2)
    #expect(archive.schemaVersion == SQLiteLedgerStore.currentSchemaVersion)
    #expect(archive.binaryEncoding == "base64")
    #expect(archive.ledgerEntries.count == 1)
    #expect(archive.currentProjections.count == 1)
    #expect(archive.syncOperations.count == 1)

    let restoredStore = try SQLiteLedgerStore(
        configuration: SQLiteLedgerConfiguration(
            databaseURL: backupURL,
            deviceID: fixture.deviceID,
            preMigrationBackupDirectory: fixture.directory,
            clock: { fixedDate }
        )
    )
    try await restoredStore.verifyIntegrity()
    #expect(try await restoredStore.entries(after: nil, limit: 10).count == 1)
}

@Test
func ledgerRejectsDifferentDeviceIdentity() async throws {
    let fixture = try LedgerFixture()
    let differentDeviceID = try fixture.identifier(99)
    do {
        _ = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: fixture.databaseURL,
                deviceID: differentDeviceID,
                preMigrationBackupDirectory: fixture.directory,
                clock: { fixedDate }
            )
        )
        Issue.record("Opening a retained outbox under another device identity should fail.")
    } catch let error as SQLiteLedgerError {
        #expect(
            error == .deviceIdentityMismatch(
                expected: differentDeviceID.description,
                found: fixture.deviceID.description
            )
        )
    }
}

private struct LedgerFixture {
    let directory: URL
    let databaseURL: URL
    let deviceID: UUIDv7
    let store: SQLiteLedgerStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("odyssey-data-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        databaseURL = directory.appendingPathComponent("ledger.sqlite3")
        deviceID = try Self.identifier(900)
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: databaseURL,
                deviceID: deviceID,
                preMigrationBackupDirectory: directory,
                clock: { fixedDate }
            )
        )
    }

    func identifier(_ value: Int) throws -> UUIDv7 {
        try Self.identifier(value)
    }

    func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func commit(
        entityID: UUIDv7,
        eventID: UUIDv7,
        operationID: UUIDv7,
        document: Data,
        mutationType: LedgerMutationType = .create,
        revision: Int = 1,
        baseRevision: Int? = nil
    ) -> LedgerCommit {
        LedgerCommit(
            entry: LedgerEntry(
                eventID: eventID,
                eventType: "capture.\(mutationType.rawValue)d",
                aggregateType: "capture",
                aggregateID: entityID,
                occurredAt: fixedDate,
                recordedAt: fixedDate,
                payload: document,
                provenanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            projection: ProjectionMutation(
                entityType: "capture",
                entityID: entityID,
                revision: revision,
                mutationType: mutationType,
                document: document
            ),
            syncMutation: SyncMutationDraft(
                operationID: operationID,
                entityType: "capture",
                entityID: entityID,
                mutationType: mutationType,
                baseRevision: baseRevision,
                payload: document,
                createdAt: fixedDate,
                sensitivityClass: .private
            )
        )
    }

    func decodeExport(at url: URL) throws -> LedgerExportArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid fixture timestamp."
                )
            }
            return date
        }
        return try decoder.decode(LedgerExportArchive.self, from: Data(contentsOf: url))
    }

    private static func identifier(_ value: Int) throws -> UUIDv7 {
        let suffix = String(format: "%012x", value)
        return try UUIDv7(
            validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
        )
    }
}
