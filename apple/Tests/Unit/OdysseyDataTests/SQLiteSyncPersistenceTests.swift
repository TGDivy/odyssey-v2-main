import Foundation
import GRDB
@testable import OdysseyData
import OdysseyDomain
import Testing

private let syncFixtureDate = Date(timeIntervalSince1970: 1_786_752_000.125)

@Test
func migrationFromV1CreatesVerifiedPreMigrationBackup() async throws {
    let directory = try makeSyncTestDirectory()
    let databaseURL = directory.appendingPathComponent("migration.sqlite3")
    let deviceID = try syncIdentifier(900)
    let databasePool = try SQLiteLedgerStore.makeDatabasePool(
        at: databaseURL,
        busyTimeoutMilliseconds: 5_000
    )
    try SQLiteLedgerStore.makeMigrator(clock: { syncFixtureDate }).migrate(
        databasePool,
        upTo: "v1-durable-ledger"
    )
    try await databasePool.write { database in
        try SQLiteLedgerStore.initializeDeviceState(
            SQLiteSession(database: database),
            deviceID: deviceID,
            clock: { syncFixtureDate }
        )
    }
    try databasePool.close()

    let store = try SQLiteLedgerStore(
        configuration: SQLiteLedgerConfiguration(
            databaseURL: databaseURL,
            deviceID: deviceID,
            preMigrationBackupDirectory: directory,
            clock: { syncFixtureDate }
        )
    )
    let backupURLs = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("odyssey-pre-migration-v1-to-v2-") }
        .filter { $0.pathExtension == "sqlite3" }

    #expect(backupURLs.count == 1)
    try SQLiteLedgerStore.verifyBackupFile(
        try #require(backupURLs.first),
        expectedSchemaVersion: 1
    )
    #expect(try await store.syncState().receiptFloor == 0)
    try await store.verifyIntegrity()
}

@Test
func pushResultsAndServerCursorCommitAtomically() async throws {
    let fixture = try SyncLedgerFixture()
    let firstOperationID = try syncIdentifier(1)
    let secondOperationID = try syncIdentifier(2)
    _ = try await fixture.store.commit(
        try fixture.createCommit(
            entityID: syncIdentifier(11),
            eventID: syncIdentifier(12),
            operationID: firstOperationID,
            text: "first"
        )
    )
    _ = try await fixture.store.commit(
        try fixture.createCommit(
            entityID: syncIdentifier(21),
            eventID: syncIdentifier(22),
            operationID: secondOperationID,
            text: "second"
        )
    )

    await #expect(throws: SQLiteLedgerError.self) {
        try await fixture.store.applyPushResult(
            SyncPushResultBatch(
                accepted: [
                    SyncPushAcceptance(
                        operationID: firstOperationID,
                        canonicalRevision: 1,
                        serverChangeID: 1,
                        mergeResult: "created"
                    ),
                    SyncPushAcceptance(
                        operationID: syncIdentifier(999),
                        canonicalRevision: 1,
                        serverChangeID: 2,
                        mergeResult: "created"
                    ),
                ],
                nextServerCursor: "c_2",
                serverSchemaVersion: 1,
                completedAt: syncFixtureDate
            )
        )
    }

    let pending = try await fixture.store.pendingSyncOperations(limit: 10, readyAt: syncFixtureDate)
    let state = try await fixture.store.syncState()
    #expect(pending.map(\.operationID) == [firstOperationID, secondOperationID])
    #expect(state.cursor == "c_0")
    #expect(state.serverCursor == "c_0")
}

@Test
func pullPageReconcilesLocalOptimismAndCommitsOtherDeviceChanges() async throws {
    let fixture = try SyncLedgerFixture()
    let localEntityID = try syncIdentifier(31)
    let localOperationID = try syncIdentifier(32)
    _ = try await fixture.store.commit(
        try fixture.createCommit(
            entityID: localEntityID,
            eventID: syncIdentifier(33),
            operationID: localOperationID,
            text: "optimistic"
        )
    )
    try await fixture.store.applyPushResult(
        SyncPushResultBatch(
            accepted: [
                SyncPushAcceptance(
                    operationID: localOperationID,
                    canonicalRevision: 1,
                    serverChangeID: 1,
                    mergeResult: "created"
                ),
            ],
            nextServerCursor: "c_1",
            serverSchemaVersion: 1,
            completedAt: syncFixtureDate
        )
    )
    let canonicalLocalPayload = try fixture.json(["schema_version": 1, "text": "canonical"])
    let localReport = try await fixture.store.applyPullPage(
        RemoteSyncPage(
            changes: [
                RemoteSyncChange(
                    changeID: 1,
                    canonicalRevision: 1,
                    entityType: "capture",
                    entityID: localEntityID,
                    mutationType: .create,
                    payload: canonicalLocalPayload,
                    tombstone: false,
                    deletionEpoch: nil,
                    mergeResult: "created",
                    originDeviceID: fixture.deviceID,
                    originOperationID: localOperationID,
                    serverReceivedAt: syncFixtureDate
                ),
            ],
            nextCursor: "c_1",
            hasMore: false,
            serverSchemaVersion: 1,
            completedAt: syncFixtureDate
        )
    )
    #expect(localReport.localReconciliationCount == 1)
    #expect(try fixture.store.projectedEntity(entityType: "capture", entityID: localEntityID)?.document == canonicalLocalPayload)

    let remoteEntityID = try syncIdentifier(41)
    let remotePayload = try fixture.json(["schema_version": 1, "text": "from mac"])
    let remoteReport = try await fixture.store.applyPullPage(
        RemoteSyncPage(
            changes: [
                RemoteSyncChange(
                    changeID: 2,
                    canonicalRevision: 1,
                    entityType: "capture",
                    entityID: remoteEntityID,
                    mutationType: .create,
                    payload: remotePayload,
                    tombstone: false,
                    deletionEpoch: nil,
                    mergeResult: "created",
                    originDeviceID: syncIdentifier(42),
                    originOperationID: syncIdentifier(43),
                    serverReceivedAt: syncFixtureDate.addingTimeInterval(1)
                ),
            ],
            nextCursor: "c_2",
            hasMore: false,
            serverSchemaVersion: 1,
            completedAt: syncFixtureDate.addingTimeInterval(1)
        )
    )
    let receipts = try await fixture.store.remoteChangeReceipts(after: nil, limit: 10)
    #expect(remoteReport.remoteCommitCount == 1)
    #expect(receipts.map(\.applicationKind) == [.localReconciliation, .remoteCommit])
    #expect(try fixture.store.projectedEntity(entityType: "capture", entityID: remoteEntityID)?.document == remotePayload)
    #expect(try fixture.store.storedEntries(limit: 10).count == 3)

    try await fixture.store.rebuildAll()
    #expect(try fixture.store.projectedEntity(entityType: "capture", entityID: localEntityID)?.document == canonicalLocalPayload)
    #expect(try fixture.store.projectedEntity(entityType: "capture", entityID: remoteEntityID)?.document == remotePayload)
    let integrity = try fixture.store.integrityReport()
    #expect(integrity.remoteChangeReceiptCount == 2)
}

@Test
func pullPageRollsBackBeforeAdvancingAcrossChangeGap() async throws {
    let fixture = try SyncLedgerFixture()
    let firstChange = try fixture.remoteCreate(changeID: 1, value: 51)
    let thirdChange = try fixture.remoteCreate(changeID: 3, value: 53)

    await #expect(throws: SQLiteLedgerError.invalidRemoteChange(
        "Remote changes must continue immediately after the applied cursor."
    )) {
        try await fixture.store.applyPullPage(
            RemoteSyncPage(
                changes: [firstChange, thirdChange],
                nextCursor: "c_3",
                hasMore: false,
                serverSchemaVersion: 1,
                completedAt: syncFixtureDate
            )
        )
    }

    #expect(try await fixture.store.remoteChangeReceipts(after: nil, limit: 10).isEmpty)
    #expect(try fixture.store.storedEntries(limit: 10).isEmpty)
    #expect(try await fixture.store.syncState().cursor == "c_0")
}

@Test
func remoteTombstoneCannotBeOverlaidByPendingLocalUpdate() async throws {
    let fixture = try SyncLedgerFixture()
    let entityID = try syncIdentifier(61)
    let remoteDeviceID = try syncIdentifier(62)
    _ = try await fixture.store.applyPullPage(
        RemoteSyncPage(
            changes: [
                RemoteSyncChange(
                    changeID: 1,
                    canonicalRevision: 1,
                    entityType: "capture",
                    entityID: entityID,
                    mutationType: .create,
                    payload: try fixture.json(["schema_version": 1, "text": "remote base"]),
                    tombstone: false,
                    deletionEpoch: nil,
                    mergeResult: "created",
                    originDeviceID: remoteDeviceID,
                    originOperationID: syncIdentifier(63),
                    serverReceivedAt: syncFixtureDate
                ),
            ],
            nextCursor: "c_1",
            hasMore: false,
            serverSchemaVersion: 1,
            completedAt: syncFixtureDate
        )
    )
    let pendingDocument = try fixture.json(["schema_version": 1, "text": "pending update"])
    _ = try await fixture.store.commit(
        fixture.updateCommit(
            entityID: entityID,
            eventID: try syncIdentifier(64),
            operationID: try syncIdentifier(65),
            document: pendingDocument
        )
    )
    #expect(try fixture.store.projectedEntity(entityType: "capture", entityID: entityID)?.tombstone == false)

    _ = try await fixture.store.applyPullPage(
        RemoteSyncPage(
            changes: [
                RemoteSyncChange(
                    changeID: 2,
                    canonicalRevision: 2,
                    entityType: "capture",
                    entityID: entityID,
                    mutationType: .delete,
                    payload: try fixture.json([:]),
                    tombstone: true,
                    deletionEpoch: 2,
                    mergeResult: "deleted",
                    originDeviceID: remoteDeviceID,
                    originOperationID: syncIdentifier(66),
                    serverReceivedAt: syncFixtureDate.addingTimeInterval(1)
                ),
            ],
            nextCursor: "c_2",
            hasMore: false,
            serverSchemaVersion: 1,
            completedAt: syncFixtureDate.addingTimeInterval(1)
        )
    )

    let storedProjection = try fixture.store.projectedEntity(
        entityType: "capture",
        entityID: entityID
    )
    let projection = try #require(storedProjection)
    #expect(projection.tombstone)
    #expect(projection.revision == 2)
    #expect(try await fixture.store.pendingSyncOperations(limit: 10, readyAt: syncFixtureDate).count == 1)
    try await fixture.store.rebuildAll()
    #expect(try fixture.store.projectedEntity(entityType: "capture", entityID: entityID)?.tombstone == true)
}

private struct SyncLedgerFixture {
    let directory: URL
    let databaseURL: URL
    let deviceID: UUIDv7
    let store: SQLiteLedgerStore

    init() throws {
        directory = try makeSyncTestDirectory()
        databaseURL = directory.appendingPathComponent("ledger.sqlite3")
        deviceID = try syncIdentifier(800)
        store = try SQLiteLedgerStore(
            configuration: SQLiteLedgerConfiguration(
                databaseURL: databaseURL,
                deviceID: deviceID,
                preMigrationBackupDirectory: directory,
                clock: { syncFixtureDate }
            )
        )
    }

    func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    func createCommit(
        entityID: UUIDv7,
        eventID: UUIDv7,
        operationID: UUIDv7,
        text: String
    ) throws -> LedgerCommit {
        let document = try json(["schema_version": 1, "text": text])
        return LedgerCommit(
            entry: LedgerEntry(
                eventID: eventID,
                eventType: "capture.created",
                aggregateType: "capture",
                aggregateID: entityID,
                occurredAt: syncFixtureDate,
                recordedAt: syncFixtureDate,
                payload: document,
                provenanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            projection: ProjectionMutation(
                entityType: "capture",
                entityID: entityID,
                revision: 1,
                mutationType: .create,
                document: document
            ),
            syncMutation: SyncMutationDraft(
                operationID: operationID,
                entityType: "capture",
                entityID: entityID,
                mutationType: .create,
                payload: document,
                createdAt: syncFixtureDate
            )
        )
    }

    func remoteCreate(changeID: Int64, value: Int) throws -> RemoteSyncChange {
        RemoteSyncChange(
            changeID: changeID,
            canonicalRevision: 1,
            entityType: "capture",
            entityID: try syncIdentifier(value),
            mutationType: .create,
            payload: try json(["schema_version": 1, "text": "remote \(value)"]),
            tombstone: false,
            deletionEpoch: nil,
            mergeResult: "created",
            originDeviceID: try syncIdentifier(value + 100),
            originOperationID: try syncIdentifier(value + 200),
            serverReceivedAt: syncFixtureDate
        )
    }

    func updateCommit(
        entityID: UUIDv7,
        eventID: UUIDv7,
        operationID: UUIDv7,
        document: Data
    ) -> LedgerCommit {
        LedgerCommit(
            entry: LedgerEntry(
                eventID: eventID,
                eventType: "capture.updated",
                aggregateType: "capture",
                aggregateID: entityID,
                occurredAt: syncFixtureDate,
                recordedAt: syncFixtureDate,
                payload: document,
                provenanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            projection: ProjectionMutation(
                entityType: "capture",
                entityID: entityID,
                revision: 2,
                mutationType: .update,
                document: document
            ),
            syncMutation: SyncMutationDraft(
                operationID: operationID,
                entityType: "capture",
                entityID: entityID,
                mutationType: .update,
                baseRevision: 1,
                payload: document,
                createdAt: syncFixtureDate
            )
        )
    }
}

private func makeSyncTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("odyssey-sync-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}

private func syncIdentifier(_ value: Int) throws -> UUIDv7 {
    let suffix = String(format: "%012x", value)
    return try UUIDv7(
        validating: UUID(uuidString: "018f0000-0000-7000-8000-\(suffix)")!
    )
}
